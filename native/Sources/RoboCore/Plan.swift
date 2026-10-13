// Today's study plan, pure and deterministic: tasks go into the free time around busy intervals, never
// overlapping busy time, never starting before now, never ending after a task's deadline. Port of
// src/robo/plan.py: `planMain` is `robo plan` (flags, files, one error line on stderr and exit 2).
//
// Times keep Python's aware-datetime semantics because the plan's output depends on them: two times in
// the same zone compare and subtract by wall clock (so a plan across a DST change counts wall minutes,
// as Python does), times in different zones compare by instant, and an ISO string without an offset is
// read in the plan's zone.
import Foundation

public struct PlanError: Error, Equatable, CustomStringConvertible {
    /// The line `robo plan` prints after "robo plan: ".
    public let message: String
    init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - datetime

/// A time zone as Python's datetime has them: a fixed offset, or a named zone with daylight saving.
public enum PlanZone {
    case fixed(Int)  // microseconds east of UTC: an ISO offset such as "+04:00" or "Z"
    case named(id: String, tz: TimeZone)  // what ZoneInfo("Asia/Dubai") is

    /// nil when there is no such zone (ZoneInfoNotFoundError). The name is matched ignoring case, because
    /// Python's ZoneInfo opens a file in /usr/share/zoneinfo and macOS volumes are case-insensitive.
    public init?(name: String) {
        let known = TimeZone.knownTimeZoneIdentifiers.first { $0.caseInsensitiveCompare(name) == .orderedSame }
        guard let tz = TimeZone(identifier: name) ?? known.flatMap({ TimeZone(identifier: $0) }) else { return nil }
        self = .named(id: name.lowercased(), tz: tz)
    }

    /// Seconds east of UTC at an instant.
    func offset(atInstant seconds: Int) -> Int {
        guard case .named(_, let tz) = self else { return 0 }
        return tz.secondsFromGMT(for: Date(timeIntervalSince1970: Double(seconds)))
    }

    /// utcoffset() in seconds of the wall-clock reading `wall` (seconds), the way zoneinfo answers it: a
    /// time that happens twice takes the first offset with fold 0 and the second with fold 1; a time that
    /// does not exist takes the offset from before the change with fold 0 and from after with fold 1.
    func offset(atWall wall: Int, fold: Int) -> Int {
        guard case .named = self else { return 0 }
        let day = 172_800  // the change nearest the reading lies within two days of it (offsets are < 1 day)
        let before = offset(atInstant: wall - day), after = offset(atInstant: wall + day)
        if before == after { return before }
        var (lo, hi) = (wall - day, wall + day)  // bisect to the first second on the new offset
        while hi - lo > 1 {
            let mid = lo + (hi - lo) / 2
            if offset(atInstant: mid) == before { lo = mid } else { hi = mid }
        }
        return wall >= hi + (fold == 0 ? max(before, after) : min(before, after)) ? after : before
    }

    func sameZone(_ o: PlanZone) -> Bool {
        switch (self, o) {
        case (.fixed(let a), .fixed(let b)): return a == b
        case (.named(let a, _), .named(let b, _)): return a == b
        default: return false
        }
    }
}

private let usPerMinute = 60_000_000
private let usPerDay = 86_400_000_000

private func floorDiv(_ a: Int, _ b: Int) -> Int { a / b - ((a % b != 0 && (a < 0) != (b < 0)) ? 1 : 0) }
private func floorMod(_ a: Int, _ b: Int) -> Int { a - floorDiv(a, b) * b }

/// Days since 1970-01-01 of a proleptic Gregorian date.
private func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
    let y = month <= 2 ? year - 1 : year
    let era = floorDiv(y, 400)
    let yoe = y - era * 400
    let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
    return era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
}

private func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
    let z = days + 719_468
    let era = floorDiv(z, 146_097)
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let month = mp < 10 ? mp + 3 : mp - 9
    return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, doy - (153 * mp + 2) / 5 + 1)
}

private func isLeap(_ y: Int) -> Bool { y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) }
private func daysInMonth(_ y: Int, _ m: Int) -> Int { m == 2 ? (isLeap(y) ? 29 : 28) : [4, 6, 9, 11].contains(m) ? 30 : 31 }

/// A timezone-aware Python `datetime`.
public struct PlanTime: Comparable {
    var wall: Int  // microseconds since 1970-01-01T00:00 of the clock reading, as if it were UTC
    var zone: PlanZone
    var fold = 0  // 1 for the second time a repeated clock reading happens

    init(wall: Int, zone: PlanZone, fold: Int = 0) { (self.wall, self.zone, self.fold) = (wall, zone, fold) }

    public init(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0,
                _ microsecond: Int = 0, zone: PlanZone) {
        self.init(wall: daysFromCivil(year, month, day) * usPerDay + ((hour * 60 + minute) * 60 + second) * 1_000_000 + microsecond,
                  zone: zone)
    }

    /// `datetime.fromtimestamp(...)` / `astimezone` for an instant given in microseconds since the epoch.
    init(instant: Int, zone: PlanZone) {
        switch zone {
        case .fixed(let off): self.init(wall: instant + off, zone: zone)
        case .named:
            let off = zone.offset(atInstant: floorDiv(instant, 1_000_000))
            let wall = instant + off * 1_000_000
            let first = zone.offset(atWall: floorDiv(wall, 1_000_000), fold: 0)
            self.init(wall: wall, zone: zone, fold: first != off ? 1 : 0)
        }
    }

    public init(_ date: Date, zone: PlanZone) {
        self.init(instant: Int((date.timeIntervalSince1970 * 1e6).rounded()), zone: zone)
    }

    /// utcoffset() in microseconds.
    var offset: Int {
        if case .fixed(let off) = zone { return off }
        return zone.offset(atWall: floorDiv(wall, 1_000_000), fold: fold) * 1_000_000
    }

    var instant: Int { wall - offset }

    /// `self - other` in microseconds: by wall clock within one zone, by instant otherwise.
    func minus(_ o: PlanTime) -> Int { zone.sameZone(o.zone) ? wall - o.wall : instant - o.instant }

    /// Across zones, a time whose offset depends on `fold` (it happens twice, or never) equals nothing: PEP 495.
    public static func == (a: PlanTime, b: PlanTime) -> Bool {
        a.minus(b) == 0 && (a.zone.sameZone(b.zone) || !(a.dependsOnFold || b.dependsOnFold))
    }

    private var dependsOnFold: Bool {
        zone.offset(atWall: floorDiv(wall, 1_000_000), fold: 1 - fold) != zone.offset(atWall: floorDiv(wall, 1_000_000), fold: fold)
    }

    public static func < (a: PlanTime, b: PlanTime) -> Bool { a.minus(b) < 0 }

    /// `self + timedelta(minutes=n)`: wall-clock arithmetic, fold reset.
    func adding(minutes n: Int) -> PlanTime { PlanTime(wall: wall + n * usPerMinute, zone: zone) }

    /// `self.astimezone(zone)`
    func converted(to z: PlanZone) -> PlanTime { zone.sameZone(z) ? self : PlanTime(instant: instant, zone: z) }

    /// The calendar date of the clock reading.
    var date: (year: Int, month: Int, day: Int) { civilFromDays(floorDiv(wall, usPerDay)) }

    /// `isoformat(timespec="minutes")`, e.g. "2026-10-12T09:00+04:00".
    public var isoMinutes: String {
        func z(_ n: Int, _ width: Int) -> String { String(repeating: "0", count: max(0, width - String(n).count)) + String(n) }
        let d = date, rest = floorMod(wall, usPerDay)
        var s = "\(z(d.year, 4))-\(z(d.month, 2))-\(z(d.day, 2))T\(z(rest / 3_600_000_000, 2)):\(z(rest / usPerMinute % 60, 2))"
        let off = abs(offset), sub = off % usPerMinute
        s += (offset < 0 ? "-" : "+") + "\(z(off / 3_600_000_000, 2)):\(z(off / usPerMinute % 60, 2))"
        if sub != 0 { s += ":\(z(sub / 1_000_000, 2))" + (sub % 1_000_000 != 0 ? ".\(z(sub % 1_000_000, 6))" : "") }
        return s
    }
}

/// Python's `max(a, b)`: `a` unless `b` is greater.
private func later(_ a: PlanTime, _ b: PlanTime) -> PlanTime { b > a ? b : a }

// MARK: - ISO 8601 as datetime.fromisoformat reads it (Python 3.14, CPython's C parser)

enum PyISO {
    struct Bytes {
        let a: [UInt8]
        subscript(i: Int) -> UInt8 { i >= 0 && i < a.count ? a[i] : 0 }  // the C parser reads the string's NUL
    }

    struct Fields {
        var year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0, micro = 0
        var tz: Int?  // microseconds east of UTC, nil without an offset
    }

    static let dash = UInt8(ascii: "-"), colon = UInt8(ascii: ":"), dot = UInt8(ascii: "."), comma = UInt8(ascii: ",")

    static func digits(_ b: Bytes, _ p: inout Int, _ n: Int) -> Int? {
        var v = 0
        for _ in 0..<n {
            let d = Int(b[p]) - 48
            p += 1
            if d < 0 || d > 9 { return nil }
            v = v * 10 + d
        }
        return v
    }

    static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

    static func weekday(_ days: Int) -> Int { floorMod(days + 3, 7) }  // Monday = 0

    static func isoToYMD(_ year: Int, _ week: Int, _ day: Int) -> (Int, Int, Int)? {
        guard (1...9999).contains(year) else { return nil }
        if !(1...52).contains(week) {  // 53 weeks only in years starting on a Thursday, or a Wednesday in a leap year
            let first = weekday(daysFromCivil(year, 1, 1))
            guard week == 53, first == 3 || (first == 2 && isLeap(year)) else { return nil }
        }
        guard (1...7).contains(day) else { return nil }
        let jan4 = daysFromCivil(year, 1, 4)
        let c = civilFromDays(jan4 - weekday(jan4) + (week - 1) * 7 + day - 1)
        return (c.year, c.month, c.day)
    }

    /// YYYY-MM-DD, YYYYMMDD, YYYY-Www[-D] or YYYYWww[D] in the first `len` bytes.
    static func date(_ b: Bytes, len: Int) -> (Int, Int, Int)? {
        var p = 0
        guard let year = digits(b, &p, 4) else { return nil }
        let sep = b[p] == dash
        if sep { p += 1 }
        if b[p] == UInt8(ascii: "W") {
            p += 1
            guard let week = digits(b, &p, 2) else { return nil }
            var day = 1
            if p < len {
                if sep { p += 1; if b[p - 1] != dash { return nil } }
                guard let d = digits(b, &p, 1) else { return nil }
                day = d
            }
            return isoToYMD(year, week, day)
        }
        guard let month = digits(b, &p, 2) else { return nil }
        if sep { p += 1; if b[p - 1] != dash { return nil } }
        guard let day = digits(b, &p, 2) else { return nil }
        return (year, month, day)
    }

    /// HH[:?MM[:?SS[{.,}f...]]] from `from` up to `end`. rv: 0 = parsed to the end, 1 = something
    /// follows, negative = malformed.
    static func hhmmssff(_ b: Bytes, _ from: Int, _ end: Int) -> (rv: Int, v: [Int]) {
        var v = [0, 0, 0, 0]
        var p = from
        var hasSep = true
        var i = 0
        while i < 3 {
            guard let n = digits(b, &p, 2) else { return (-3, v) }
            v[i] = n
            let c = b[p]
            p += 1
            if i == 0 { hasSep = c == colon }
            if p >= end { return c == dot || c == comma ? (-3, v) : (c != 0 ? 1 : 0, v) }  // a mark with no digits after it (3.14.0 let it by before an offset)
            if hasSep && c == colon {
                if i == 2 { return (-4, v) }
                i += 1
                continue
            }
            if c == dot || c == comma {
                if i < 2 { return (-3, v) }
                break
            }
            if !hasSep { p -= 1 } else { return (-4, v) }
            i += 1
        }
        let toParse = min(end - p, 6)
        guard var us = digits(b, &p, toParse) else { return (-3, v) }
        if toParse < 6 { us *= [100_000, 10_000, 1000, 100, 10][toParse - 1] }
        v[3] = us
        while isDigit(b[p]) { p += 1 }  // digits past the sixth are dropped
        return (b[p] != 0 ? 1 : 0, v)
    }

    /// The time of day and optional offset in `len` bytes from `start`; rv 0 = no offset, 1 = offset.
    static func time(_ b: Bytes, _ start: Int, _ len: Int) -> (rv: Int, f: Fields) {
        var f = Fields()
        let end = start + len
        guard len > 0 else { return (-3, f) }
        var tzPos = start
        while tzPos < end, ![UInt8(ascii: "Z"), UInt8(ascii: "+"), dash].contains(b[tzPos]) { tzPos += 1 }
        let t = hhmmssff(b, start, tzPos)
        (f.hour, f.minute, f.second, f.micro) = (t.v[0], t.v[1], t.v[2], t.v[3])
        if t.rv < 0 { return (t.rv, f) }
        if tzPos == end { return (t.rv == 1 ? -5 : 0, f) }  // text left over and no offset to explain it
        if b[tzPos] == UInt8(ascii: "Z") {
            f.tz = 0
            return (b[tzPos + 1] != 0 ? -5 : 1, f)
        }
        let sign = b[tzPos] == dash ? -1 : 1
        let z = hhmmssff(b, tzPos + 1, end)
        let seconds = sign * (z.v[0] * 3600 + z.v[1] * 60 + z.v[2])
        f.tz = seconds * 1_000_000 + sign * z.v[3]  // all zeros is UTC; 3.14.0 also made "+00:00:00.5" UTC
        return (z.rv != 0 ? -5 : 1, f)
    }

    static func valid(_ f: Fields) -> Bool {
        (1...9999).contains(f.year) && (1...12).contains(f.month) && (1...daysInMonth(f.year, f.month)).contains(f.day)
            && (0...23).contains(f.hour) && (0...59).contains(f.minute) && (0...59).contains(f.second)
            && f.tz.map({ abs($0) < usPerDay }) ?? true
    }

    /// Where the date ends and the one separator character starts.
    static func separator(_ b: Bytes, _ len: Int) -> Int? {
        if len == 7 { return 7 }
        if b[4] == dash {
            guard b[5] == UInt8(ascii: "W") else { return 10 }
            if len > 8 && b[8] == dash {
                if len == 9 { return nil }
                return len > 10 && isDigit(b[10]) ? 8 : 10
            }
            return 8
        }
        guard b[4] == UInt8(ascii: "W") else { return 8 }
        var idx = 7
        while idx < len, isDigit(b[idx]) { idx += 1 }
        if idx < 9 { return idx }
        return idx % 2 == 0 ? 7 : 8
    }

    /// `datetime.fromisoformat(s)`, nil where Python raises ValueError.
    static func datetime(_ s: String) -> Fields? {
        let bytes = Array(s.utf8), b = Bytes(a: bytes), len = bytes.count
        guard len >= 7, let sepAt = separator(b, len), let d = date(b, len: sepAt) else { return nil }
        var f = Fields()
        (f.year, f.month, f.day) = d
        if len > sepAt {
            let lead = b[sepAt]  // the separator may be any character, so skip a whole UTF-8 sequence
            let p = sepAt + (lead & 0x80 == 0 ? 1 : lead & 0xf0 == 0xe0 ? 3 : lead & 0xf0 == 0xf0 ? 4 : 2)
            let t = time(b, p, len - p)
            guard t.rv >= 0 else { return nil }
            (f.hour, f.minute, f.second, f.micro, f.tz) = (t.f.hour, t.f.minute, t.f.second, t.f.micro, t.f.tz)
        }
        if f.hour == 24, f.month <= 12, f.day <= daysInMonth(f.year, f.month) {
            guard f.minute == 0, f.second == 0, f.micro == 0 else { return nil }
            f.hour = 0
            f.day += 1
            if f.day > daysInMonth(f.year, f.month) { (f.day, f.month) = (1, f.month + 1) }
            if f.month > 12 { (f.month, f.year) = (1, f.year + 1) }
        }
        return valid(f) ? f : nil
    }

    /// `date.fromisoformat(s)`.
    static func date(_ s: String) -> (year: Int, month: Int, day: Int)? {
        let bytes = Array(s.utf8)
        guard [7, 8, 10].contains(bytes.count), let d = date(Bytes(a: bytes), len: bytes.count) else { return nil }
        let f = Fields(year: d.0, month: d.1, day: d.2)
        return valid(f) ? d : nil
    }

    /// `time.fromisoformat(s)`: the time of day in microseconds (an offset is checked, then ignored).
    static func time(_ s: String) -> Int? {
        var bytes = Array(s.utf8)
        if bytes.first == UInt8(ascii: "T") { bytes.removeFirst() }
        var t = time(Bytes(a: bytes), 0, bytes.count)
        guard t.rv >= 0 else { return nil }
        if t.f.hour == 24 {
            guard t.f.minute == 0, t.f.second == 0, t.f.micro == 0 else { return nil }
            t.f.hour = 0
        }
        let f = Fields(year: 2000, month: 1, day: 1, hour: t.f.hour, minute: t.f.minute, second: t.f.second, micro: t.f.micro, tz: t.f.tz)
        return valid(f) ? ((f.hour * 60 + f.minute) * 60 + f.second) * 1_000_000 + f.micro : nil
    }
}

// MARK: - the plan

/// A stretch of time that is taken (a lecture, a meeting).
public struct PlanBusy {
    public var start: PlanTime, end: PlanTime
    public init(_ start: PlanTime, _ end: PlanTime) { (self.start, self.end) = (start, end) }
}

/// Something to study: `minutes` of work, optionally due by `deadline`; a higher `priority` goes first.
public struct PlanTask {
    public var id: String, title: String, minutes: Int
    public var deadline: PlanTime?
    public var priority: Double  // 0...1, higher goes first

    static let badMinutes = "minutes must be a positive whole number"
    static let badPriority = "priority must be a number from 0 to 1"

    public init(id: String, title: String, minutes: Int, deadline: PlanTime? = nil, priority: Double = 0.5) throws {
        guard minutes >= 1 else { throw PlanError(Self.badMinutes) }
        guard 0 <= priority && priority <= 1 else { throw PlanError(Self.badPriority) }
        (self.id, self.title, self.minutes, self.deadline, self.priority) = (id, title, minutes, deadline, priority)
    }
}

/// One stretch of work on a task, placed in the day.
public struct PlanBlock {
    public var taskId: String, title: String
    public var start: PlanTime, end: PlanTime
}

/// Python's sorted(): stable, which Swift's sort does not promise.
private func stableSorted<T>(_ a: [T], _ less: (T, T) -> Bool) -> [T] {
    a.enumerated().sorted { less($0.element, $1.element) || (!less($1.element, $0.element) && $0.offset < $1.offset) }
        .map(\.element)
}

/// Python's str ordering is by code point, which is byte order in UTF-8 (Swift's String < is not).
private func before(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

/// Free (start, end) windows in [dayStart, dayEnd), ordered and disjoint. Windows shorter than
/// `minMinutes` are dropped; empty or backwards busy entries are ignored.
public func freeSlots(_ busy: [PlanBusy], dayStart: PlanTime, dayEnd: PlanTime, minMinutes: Int = 25)
    -> [(start: PlanTime, end: PlanTime)] {
    var gaps: [(start: PlanTime, end: PlanTime)] = []
    var cursor = dayStart
    for b in stableSorted(busy, { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }) {
        if b.start >= dayEnd { break }
        if b.end <= later(cursor, b.start) { continue }
        if b.start > cursor { gaps.append((cursor, b.start)) }
        cursor = b.end
    }
    if cursor < dayEnd { gaps.append((cursor, dayEnd)) }
    return gaps.filter { $0.end.minus($0.start) >= minMinutes * usPerMinute }
}

/// Round up to whole five minutes, so a plan reads like a person wrote it.
private func ceil5(_ t: PlanTime) -> PlanTime {
    let floor = t.wall - floorMod(t.wall, usPerMinute)
    let down = floor - (floorMod(floor, 3_600_000_000) / usPerMinute % 5) * usPerMinute
    return PlanTime(wall: down == t.wall ? down : down + 5 * usPerMinute, zone: t.zone)
}

/// Blocks ordered by start. Tasks go highest priority first, then nearest deadline (then id, so input
/// order never matters). Each is split into near-equal blocks of at most `maxBlock` minutes, each at
/// the earliest free time that fits, `breakMin` after any block before it in the same window. A block
/// that cannot end by its deadline is skipped; see `unscheduled`.
public func planDay(_ tasks: [PlanTask], _ busy: [PlanBusy], dayStart: PlanTime, dayEnd: PlanTime, now: PlanTime,
                    maxBlock: Int = 90, breakMin: Int = 10, minBlock: Int = 25) -> [PlanBlock] {
    var free = freeSlots(busy, dayStart: later(dayStart, now), dayEnd: dayEnd, minMinutes: minBlock)
    var blocks: [PlanBlock] = []
    let order = stableSorted(tasks) { a, b in
        if a.priority != b.priority { return a.priority > b.priority }
        if (a.deadline == nil) != (b.deadline == nil) { return a.deadline != nil }
        if let da = a.deadline, let db = b.deadline, da != db { return da < db }
        return before(a.id, b.id)
    }
    for task in order {
        // near-equal parts of at most maxBlock minutes that sum to exactly task.minutes: r of q + 1, then q
        let n = (task.minutes - 1) / maxBlock + 1
        let (q, r) = (task.minutes / n, task.minutes % n)
        var part = 0
        while part < n {
            let minutes = part < r ? q + 1 : q
            var placed = false
            for (i, (s, e)) in free.enumerated() {
                let start = ceil5(s)
                let end = start.adding(minutes: minutes)
                if let deadline = task.deadline, end > deadline { break }  // windows are ordered, so every later one ends later still
                if end <= e {
                    let rest = end.adding(minutes: breakMin)
                    free.replaceSubrange(i...i, with: rest < e ? [(rest, e)] : [])
                    blocks.append(PlanBlock(taskId: task.id, title: task.title, start: start, end: end))
                    placed = true
                    break
                }
            }
            // A part that finds no room changes nothing, so every part of its size after it finds none either:
            // skip them (Python tries each, which for a billion minutes is a billion scans).
            part = placed ? part + 1 : (part < r ? r : n)
        }
    }
    return stableSorted(blocks) { a, b in a.start != b.start ? a.start < b.start : before(a.taskId, b.taskId) }
}

/// (task, minutes the plan could not place) for every task not fully placed.
public func unscheduled(_ tasks: [PlanTask], _ blocks: [PlanBlock]) -> [(task: PlanTask, minutes: Int)] {
    var placed: [[UInt8]: Int] = [:]  // keyed by UTF-8: Swift's String == equates canonically equivalent text
    for b in blocks { placed[Array(b.taskId.utf8), default: 0] += floorDiv(b.end.minus(b.start), usPerMinute) }
    return tasks.compactMap { t in
        let done = placed[Array(t.id.utf8)] ?? 0
        return done < t.minutes ? (t, t.minutes - done) : nil
    }
}

// MARK: - robo plan: JSON in, JSON out

private func rows(_ data: PyJSON, _ name: String) throws -> [PyJSON] {
    guard case .array(let items) = data, items.allSatisfy({ if case .object = $0 { return true } else { return false } }) else {
        throw PlanError("\(name): expected a JSON list of objects")
    }
    return items
}

/// An ISO datetime; one without an offset is read in `zone`.
private func when(_ value: PyJSON?, _ zone: PlanZone, _ where_: String) throws -> PlanTime {
    guard case .string(let s)? = value, let f = PyISO.datetime(s) else {
        throw PlanError("\(where_): not an ISO datetime: \((value ?? .null).repr)")
    }
    let wall = PlanTime(f.year, f.month, f.day, f.hour, f.minute, f.second, f.micro, zone: .fixed(0)).wall
    return PlanTime(wall: wall, zone: f.tz.map { .fixed($0) } ?? zone)
}

private func planTasks(_ data: PyJSON, _ zone: PlanZone) throws -> [PlanTask] {
    var tasks: [PlanTask] = []
    for (i, r) in try rows(data, "tasks").enumerated() {
        let where_ = "tasks[\(i)]"
        var deadline: PlanTime?
        switch r.get("deadline") {
        case nil, .null?: break
        case let d?: deadline = try when(d, zone, "\(where_).deadline")
        }
        func field(_ key: String) throws -> PyJSON {
            guard let v = r.get(key) else { throw PlanError("\(where_): missing \(pyRepr(key))") }
            return v
        }
        let id = try field("id").str, title = try field("title").str
        guard case .int(let m) = try field("minutes"), m >= 1 else { throw PlanError("\(where_): \(PlanTask.badMinutes)") }
        let p: Double
        switch r.get("priority") ?? .double(0.5) {
        case .int(let n): p = Double(n)
        case .double(let d): p = d
        default: throw PlanError("\(where_): \(PlanTask.badPriority)")
        }
        do {
            tasks.append(try PlanTask(id: id, title: title, minutes: m, deadline: deadline, priority: p))
        } catch let e as PlanError {
            throw PlanError("\(where_): \(e.message)")
        }
    }
    var seen: [[UInt8]: Int] = [:], order: [[UInt8]] = []
    for t in tasks {
        let key = Array(t.id.utf8)
        if seen[key] == nil { order.append(key) }
        seen[key, default: 0] += 1
    }
    // `if dup := next(...)` in Python tests the id's truthiness: when the first repeated id is "" nothing is reported
    if let dup = order.first(where: { seen[$0]! > 1 }), !dup.isEmpty {
        throw PlanError("tasks: duplicate id \(pyRepr(String(decoding: dup, as: UTF8.self)))")
    }
    return tasks
}

private func planBusy(_ data: PyJSON, _ zone: PlanZone) throws -> [PlanBusy] {
    try rows(data, "busy").enumerated().map { i, r in
        PlanBusy(try when(r.get("start"), zone, "busy[\(i)].start"), try when(r.get("end"), zone, "busy[\(i)].end"))
    }
}

/// Everything `robo plan` does once its arguments are parsed; the two loaders read the task and busy
/// documents at the point where the Python reads them, so the first error to win is the same.
private func plan(tasks loadTasks: () throws -> PyJSON, busy loadBusy: (() throws -> PyJSON)?, day: String?,
                  start: String, end: String, tz: String, now: Date) throws -> String {
    guard let zone = PlanZone(name: tz) else { throw PlanError("--tz: unknown time zone \(pyRepr(tz))") }
    let nowTime = PlanTime(now, zone: zone)
    let date: (year: Int, month: Int, day: Int)
    if let day, !day.isEmpty {
        guard let d = PyISO.date(day) else { throw PlanError("--day: expected YYYY-MM-DD, got \(pyRepr(day))") }
        date = d
    } else {
        date = nowTime.date
    }
    let midnight = PlanTime(date.year, date.month, date.day, zone: zone).wall
    func clock(_ text: String, _ flag: String) throws -> PlanTime {
        guard let us = PyISO.time(text) else { throw PlanError("\(flag): expected HH:MM, got \(pyRepr(text))") }
        return PlanTime(wall: midnight + us, zone: zone)
    }
    let dayStart = try clock(start, "--start"), dayEnd = try clock(end, "--end")
    if dayEnd <= dayStart { throw PlanError("--end must be after --start") }
    let tasks = try planTasks(try loadTasks(), zone)
    let busy = try loadBusy.map { try planBusy(try $0(), zone) } ?? []
    let blocks = planDay(tasks, busy, dayStart: dayStart, dayEnd: dayEnd, now: nowTime)
    func iso(_ t: PlanTime) -> PyJSON { .string(t.converted(to: zone).isoMinutes) }
    return PyJSON.object([
        ("blocks", .array(blocks.map { .object([("title", .string($0.title)), ("start", iso($0.start)), ("end", iso($0.end))]) })),
        ("unscheduled", .array(unscheduled(tasks, blocks).map {
            .object([("id", .string($0.task.id)), ("title", .string($0.task.title)), ("minutes", .int($0.minutes))])
        })),
    ]).dumps()
}

/// What `robo plan` prints and its exit status.
public struct PlanOutput: Equatable {
    public var status: Int32
    public var stdout: String, stderr: String
}

private let planHelp = """
    usage: robo plan [-h] --tasks FILE [--busy FILE] [--day DAY] [--start START]
                     [--end END] [--tz TZ]

    Plan a day of study blocks around busy time. Prints {"blocks": [{title, start,
    end}], "unscheduled": [{id, title, minutes}]}.

    options:
      -h, --help     show this help message and exit
      --tasks FILE   JSON list (or - for stdin): [{"id", "title", "minutes",
                     "deadline"?, "priority"? 0..1}]
      --busy FILE    JSON list (or -): [{"start", "end"}], ISO times
      --day DAY      YYYY-MM-DD (default: today)
      --start START  HH:MM (default 08:00)
      --end END      HH:MM (default 22:00)
      --tz TZ        time zone (default Asia/Dubai); also used for ISO times
                     without an offset

    """

private func readFile(_ path: String) throws -> Data {
    let fd = open(path.isEmpty ? "." : path, O_RDONLY)  // Path("") is the current directory
    var failure = errno
    if fd >= 0 {
        defer { close(fd) }
        var out = Data(), buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n == 0 { return out }
            if n < 0 { failure = errno; break }
            out.append(contentsOf: buffer[..<n])
        }
    }
    throw PlanError("cannot read \(path): \(String(cString: strerror(failure)))")
}

/// `robo plan` with the arguments after "plan": what it would print and its exit status (0, or 2 for bad
/// input with one line on stderr). `stdin` is read only for a `-` argument.
public func planMain(_ argv: [String], now: Date = Date(),
                     stdin: @escaping () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }) -> PlanOutput {
    do {
        guard let a = try PlanArgs(argv) else { return PlanOutput(status: 0, stdout: planHelp, stderr: "") }
        if a.tasks == "-" && a.busy == "-" { throw PlanError("only one of --tasks and --busy can read stdin ('-')") }
        func load(_ src: String) throws -> PyJSON {
            let name = src == "-" ? "stdin" : src
            do {
                return src == "-" ? try PyJSON.parse(String(decoding: stdin(), as: UTF8.self))
                    : try PyJSON.parse(utf8: try readFile(src))
            } catch let e as PyJSONError {
                throw PlanError("\(name): invalid JSON (\(e.message))")
            }
        }
        let busy = a.busy.flatMap { $0.isEmpty ? nil : $0 }  // `if a.busy`: an empty name is no --busy at all
        let out = try plan(tasks: { try load(a.tasks) }, busy: busy.map { src in { try load(src) } },
                           day: a.day, start: a.start, end: a.end, tz: a.tz, now: now)
        return PlanOutput(status: 0, stdout: out + "\n", stderr: "")
    } catch {
        return PlanOutput(status: 2, stdout: "", stderr: "robo plan: \((error as? PlanError)?.message ?? "\(error)")\n")
    }
}

/// The flags of `robo plan`, parsed the way argparse does: `--flag value` or `--flag=value`, any unique
/// prefix of a long flag, the last occurrence wins, anything left over is an error.
private struct PlanArgs {
    var tasks = "", busy: String?, day: String?, start = "08:00", end = "22:00", tz = "Asia/Dubai"

    private enum Token {
        case plain  // a value, or an extra argument
        case unknown  // looks like an option but is none of ours
        case flag(String, value: String?)  // value: the part after "=", if any
    }

    private static let flags = ["-h", "--help", "--tasks", "--busy", "--day", "--start", "--end", "--tz"]

    private static func token(_ arg: String) throws -> Token {
        guard arg.hasPrefix("-"), arg.utf8.count > 1 else { return .plain }
        if flags.contains(arg) { return .flag(arg, value: nil) }
        let (name, value) = arg.firstIndex(of: "=").map { (String(arg[..<$0]), String(arg[arg.index(after: $0)...])) }
            ?? (arg, nil)
        if value != nil, flags.contains(name) { return .flag(name, value: value) }
        let matches = arg.hasPrefix("--") ? flags.filter { $0.hasPrefix(name) } : (arg.hasPrefix("-h") ? ["-h"] : [])
        if matches.count > 1 { throw PlanError("ambiguous option: \(arg) could match \(matches.joined(separator: ", "))") }
        if let flag = matches.first { return .flag(flag, value: value) }
        // a negative number or text with a space in it is an argument, not a mistyped option
        return arg.range(of: #"^-(\d+|\d*\.\d+)$"#, options: .regularExpression) != nil || arg.contains(" ") ? .plain : .unknown
    }

    /// nil for -h / --help.
    init?(_ argv: [String]) throws {
        let dashes = argv.firstIndex(of: "--") ?? argv.count  // from there on, everything is an extra argument
        let tokens = try argv[..<dashes].map(Self.token)  // classified first: an ambiguous prefix is reported before anything else
        var extras: [String] = []
        var found = false
        var i = 0
        while i < tokens.count {
            defer { i += 1 }
            guard case .flag(let flag, var value) = tokens[i] else { extras.append(argv[i]); continue }
            if flag == "-h" || flag == "--help" { return nil }
            if value == nil {
                guard i + 1 < tokens.count, case .plain = tokens[i + 1] else { throw PlanError("argument \(flag): expected one argument") }
                i += 1
                value = argv[i]
            }
            switch flag {
            case "--tasks": (tasks, found) = (value!, true)
            case "--busy": busy = value
            case "--day": day = value
            case "--start": start = value!
            case "--end": end = value!
            default: tz = value!
            }
        }
        if !found { throw PlanError("the following arguments are required: --tasks") }
        extras += argv[dashes...]
        if !extras.isEmpty { throw PlanError("unrecognized arguments: \(extras.joined(separator: " "))") }
    }
}
