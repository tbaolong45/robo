// Today's study plan, pure and deterministic: tasks go into the free time around busy intervals, never
// overlapping busy time, never starting before now, never ending after a task's deadline.
// `planMain` is `robo plan` (flags, files, one error line on stderr and exit 2).
//
// Times are instants. The plan's zone only matters for reading a time without an offset and for printing.
import Foundation

public struct PlanError: Error, Equatable, CustomStringConvertible {
    /// The line `robo plan` prints after "robo plan: ".
    public let message: String
    init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - reading and printing times

private let isoTime = #/(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,]\d+)?)?(Z|[+-]\d{2}(?::?\d{2})?)?)?/#.asciiOnlyDigits()
private let clockTime = #/(\d{2}):(\d{2})/#.asciiOnlyDigits()

private func calendar(_ zone: TimeZone) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = zone
    return c
}

/// `YYYY-MM-DD`, optionally with `T` or a space and `HH:MM[:SS[.fff]]`, then `Z` or `+HH[[:]MM]`. Without an offset
/// the time is read in `zone`. A fraction of a second is dropped; nil if it is not a real time.
func planTime(_ text: String, zone: TimeZone) -> Date? {
    guard let m = try? isoTime.wholeMatch(in: text) else { return nil }
    let (year, month, day) = (Int(m.1)!, Int(m.2)!, Int(m.3)!)
    let (hour, minute, second) = (m.4.map { Int($0)! } ?? 0, m.5.map { Int($0)! } ?? 0, m.6.map { Int($0)! } ?? 0)
    guard hour < 24, minute < 60, second < 60 else { return nil }
    var offset = 0
    if let z = m.7, z != "Z" {
        let digits = z.dropFirst().filter { $0 != ":" }
        let (h, min) = (Int(digits.prefix(2))!, Int(digits.dropFirst(2)) ?? 0)
        guard h < 24, min < 60 else { return nil }
        offset = (z.first == "-" ? -1 : 1) * (h * 3600 + min * 60)
    }
    let cal = calendar(m.7 == nil ? zone : TimeZone(secondsFromGMT: 0)!)
    guard let date = cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) else { return nil }
    // Calendar rolls 30 February over to March instead of refusing it
    let back = cal.dateComponents([.year, .month, .day], from: date)
    guard back.year == year, back.month == month, back.day == day else { return nil }
    return date.addingTimeInterval(Double(-offset))
}

/// "2026-10-12T09:00+04:00".
func planISO(_ date: Date, zone: TimeZone) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = calendar(zone)
    f.timeZone = zone
    f.dateFormat = "yyyy-MM-dd'T'HH:mmxxx"
    return f.string(from: date)
}

// MARK: - the plan

/// A stretch of time that is taken (a lecture, a meeting).
public struct PlanBusy {
    public var start: Date, end: Date
    public init(_ start: Date, _ end: Date) { (self.start, self.end) = (start, end) }
}

/// Something to study: `minutes` of work, optionally due by `deadline`; a higher `priority` goes first.
public struct PlanTask {
    public var id: String, title: String, minutes: Int
    public var deadline: Date?
    public var priority: Double  // 0...1, higher goes first

    static let badMinutes = "minutes must be a positive whole number"
    static let badPriority = "priority must be a number from 0 to 1"

    public init(id: String, title: String, minutes: Int, deadline: Date? = nil, priority: Double = 0.5) throws {
        guard minutes >= 1 else { throw PlanError(Self.badMinutes) }
        guard 0 <= priority && priority <= 1 else { throw PlanError(Self.badPriority) }
        (self.id, self.title, self.minutes, self.deadline, self.priority) = (id, title, minutes, deadline, priority)
    }
}

/// One stretch of work on a task, placed in the day.
public struct PlanBlock {
    public var taskId: String, title: String
    public var start: Date, end: Date
}

/// Free (start, end) windows in [dayStart, dayEnd), ordered and disjoint. Windows shorter than
/// `minMinutes` are dropped; empty or backwards busy entries are ignored.
public func freeSlots(_ busy: [PlanBusy], dayStart: Date, dayEnd: Date, minMinutes: Int = 25)
    -> [(start: Date, end: Date)] {
    var gaps: [(start: Date, end: Date)] = []
    var cursor = dayStart
    for b in busy.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
        if b.start >= dayEnd { break }
        if b.end <= max(cursor, b.start) { continue }
        if b.start > cursor { gaps.append((cursor, b.start)) }
        cursor = b.end
    }
    if cursor < dayEnd { gaps.append((cursor, dayEnd)) }
    return gaps.filter { $0.end.timeIntervalSince($0.start) >= Double(minMinutes) * 60 }
}

/// Round up to whole five minutes, so a plan reads like a person wrote it. Every zone's offset today is a
/// multiple of five minutes, so this lands on :00, :05... of the clock on the wall too.
private func ceil5(_ t: Date) -> Date {
    Date(timeIntervalSince1970: (t.timeIntervalSince1970 / 300).rounded(.up) * 300)
}

/// Blocks ordered by start. Tasks go highest priority first, then nearest deadline (then id, so input
/// order never matters). Each is split into near-equal blocks of at most `maxBlock` minutes, each at
/// the earliest free time that fits, `breakMin` after any block before it in the same window. A block
/// that cannot end by its deadline is skipped; see `unscheduled`.
public func planDay(_ tasks: [PlanTask], _ busy: [PlanBusy], dayStart: Date, dayEnd: Date, now: Date,
                    maxBlock: Int = 90, breakMin: Int = 10, minBlock: Int = 25) -> [PlanBlock] {
    var free = freeSlots(busy, dayStart: max(dayStart, now), dayEnd: dayEnd, minMinutes: minBlock)
    var blocks: [PlanBlock] = []
    let order = tasks.sorted { a, b in
        if a.priority != b.priority { return a.priority > b.priority }
        if (a.deadline == nil) != (b.deadline == nil) { return a.deadline != nil }
        if let da = a.deadline, let db = b.deadline, da != db { return da < db }
        return a.id < b.id
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
                let end = start.addingTimeInterval(Double(minutes) * 60)
                if let deadline = task.deadline, end > deadline { break }  // windows are ordered, so every later one ends later still
                if end <= e {
                    let rest = end.addingTimeInterval(Double(breakMin) * 60)
                    free.replaceSubrange(i...i, with: rest < e ? [(rest, e)] : [])
                    blocks.append(PlanBlock(taskId: task.id, title: task.title, start: start, end: end))
                    placed = true
                    break
                }
            }
            // A part that finds no room changes nothing, so every part of its size after it finds none either:
            // skip them, or a billion minutes is a billion scans.
            part = placed ? part + 1 : (part < r ? r : n)
        }
    }
    return blocks.sorted { a, b in a.start != b.start ? a.start < b.start : a.taskId < b.taskId }
}

/// (task, minutes the plan could not place) for every task not fully placed.
public func unscheduled(_ tasks: [PlanTask], _ blocks: [PlanBlock]) -> [(task: PlanTask, minutes: Int)] {
    var placed: [String: Int] = [:]
    for b in blocks { placed[b.taskId, default: 0] += Int((b.end.timeIntervalSince(b.start) / 60).rounded()) }
    return tasks.compactMap { t in
        let done = placed[t.id] ?? 0
        return done < t.minutes ? (t, t.minutes - done) : nil
    }
}

// MARK: - robo plan: JSON in, JSON out

private struct TaskRow: Decodable {
    let id: String, title: String, minutes: Double  // Double, so 1.5 is told apart from a broken file
    let deadline: String?, priority: Double?
}

private struct BusyRow: Decodable { let start: String, end: String }

private struct PlanReport: Encodable {
    struct Block: Encodable { let title: String, start: String, end: String }
    struct Left: Encodable { let id: String, title: String, minutes: Int }
    let blocks: [Block], unscheduled: [Left]
}

/// The list in `data`, with a line that tells the agent what to fix: "tasks[0]: missing 'minutes'".
private func rows<T: Decodable>(_ data: Data, _ name: String) throws -> [T] {
    func place(_ path: [CodingKey]) -> String {
        path.reduce(name) { $0 + ($1.intValue.map { "[\($0)]" } ?? ".\($1.stringValue)") }
    }
    do {
        return try JSONDecoder().decode([T].self, from: data)
    } catch DecodingError.keyNotFound(let key, let c) {
        throw PlanError("\(place(c.codingPath)): missing '\(key.stringValue)'")
    } catch DecodingError.dataCorrupted(let c) where c.codingPath.isEmpty {
        let why = (c.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String ?? c.debugDescription
        throw PlanError("\(name): invalid JSON (\(why.replacingOccurrences(of: "\n", with: " ")))")
    } catch let e as DecodingError {
        let path: [CodingKey]
        switch e {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): path = c.codingPath
        default: path = []
        }
        throw PlanError(path.isEmpty ? "\(name): expected a JSON list of objects" : "\(place(path)): has the wrong type")
    }
}

/// A time from the input, or a line naming where it was.
private func when(_ text: String, _ zone: TimeZone, _ place: String) throws -> Date {
    guard let t = planTime(text, zone: zone) else { throw PlanError("\(place): not an ISO datetime: '\(text)'") }
    return t
}

private func planTasks(_ data: Data, _ zone: TimeZone) throws -> [PlanTask] {
    let tasks: [PlanTask] = try (rows(data, "tasks") as [TaskRow]).enumerated().map { i, r in
        let deadline = try r.deadline.map { try when($0, zone, "tasks[\(i)].deadline") }
        do {
            guard let minutes = Int(exactly: r.minutes) else { throw PlanError(PlanTask.badMinutes) }
            return try PlanTask(id: r.id, title: r.title, minutes: minutes, deadline: deadline, priority: r.priority ?? 0.5)
        } catch let e as PlanError {
            throw PlanError("tasks[\(i)]: \(e.message)")
        }
    }
    var seen = Set<String>()
    for t in tasks where !seen.insert(t.id).inserted { throw PlanError("tasks: duplicate id '\(t.id)'") }
    return tasks
}

private func planBusy(_ data: Data, _ zone: TimeZone) throws -> [PlanBusy] {
    try (rows(data, "busy") as [BusyRow]).enumerated().map { i, r in
        PlanBusy(try when(r.start, zone, "busy[\(i)].start"), try when(r.end, zone, "busy[\(i)].end"))
    }
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

/// `robo plan` with the arguments after "plan": what it would print and its exit status (0, or 2 for bad
/// input with one line on stderr). `stdin` is read only for a `-` argument.
public func planMain(_ argv: [String], now: Date = Date(),
                     stdin: @escaping () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }) -> PlanOutput {
    do {
        guard let a = try PlanArgs(argv) else { return PlanOutput(status: 0, stdout: planHelp, stderr: "") }
        if a.tasks == "-" && a.busy == "-" { throw PlanError("only one of --tasks and --busy can read stdin ('-')") }
        guard let zone = TimeZone(identifier: a.tz) else { throw PlanError("--tz: unknown time zone '\(a.tz)'") }
        let cal = calendar(zone)
        var date = cal.dateComponents([.year, .month, .day], from: now)
        if let day = a.day {
            guard day.utf8.count == 10, let d = planTime(day, zone: zone) else { throw PlanError("--day: expected YYYY-MM-DD, got '\(day)'") }
            date = cal.dateComponents([.year, .month, .day], from: d)
        }
        func clock(_ text: String, _ flag: String) throws -> Date {
            guard let m = try? clockTime.wholeMatch(in: text), let h = Int(m.1), let min = Int(m.2), h < 24, min < 60 else {
                throw PlanError("\(flag): expected HH:MM, got '\(text)'")
            }
            var c = date
            (c.hour, c.minute) = (h, min)
            return cal.date(from: c)!
        }
        let dayStart = try clock(a.start, "--start"), dayEnd = try clock(a.end, "--end")
        if dayEnd <= dayStart { throw PlanError("--end must be after --start") }
        func load(_ source: String) throws -> Data {
            if source == "-" { return stdin() }
            do {
                return try Data(contentsOf: URL(fileURLWithPath: source))
            } catch {
                throw PlanError("cannot read \(source): \(error.localizedDescription)")
            }
        }
        let tasks = try planTasks(try load(a.tasks), zone)
        let busy = try a.busy.map { try planBusy(try load($0), zone) } ?? []
        let blocks = planDay(tasks, busy, dayStart: dayStart, dayEnd: dayEnd, now: now)
        let report = PlanReport(
            blocks: blocks.map { .init(title: $0.title, start: planISO($0.start, zone: zone), end: planISO($0.end, zone: zone)) },
            unscheduled: unscheduled(tasks, blocks).map { .init(id: $0.task.id, title: $0.task.title, minutes: $0.minutes) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return PlanOutput(status: 0, stdout: String(decoding: try encoder.encode(report), as: UTF8.self) + "\n", stderr: "")
    } catch {
        return PlanOutput(status: 2, stdout: "", stderr: "robo plan: \((error as? PlanError)?.message ?? "\(error)")\n")
    }
}

/// The flags of `robo plan`: `--flag value` or `--flag=value`; the last occurrence wins.
private struct PlanArgs {
    var tasks = "", busy: String?, day: String?, start = "08:00", end = "22:00", tz = "Asia/Dubai"

    /// nil for -h / --help.
    init?(_ argv: [String]) throws {
        var rest = argv[...]
        var found = false
        while let arg = rest.popFirst() {
            if arg == "-h" || arg == "--help" { return nil }
            let parts = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let flag = parts[0]
            guard ["--tasks", "--busy", "--day", "--start", "--end", "--tz"].contains(flag) else {
                throw PlanError("unrecognized argument: \(arg)")
            }
            guard let value = parts.count > 1 ? parts[1] : rest.first, !value.hasPrefix("--") else {
                throw PlanError("argument \(flag): expected one argument")
            }
            if parts.count == 1 { rest.removeFirst() }
            switch flag {
            case "--tasks": (tasks, found) = (value, true)
            case "--busy": busy = value
            case "--day": day = value
            case "--start": start = value
            case "--end": end = value
            default: tz = value
            }
        }
        if !found { throw PlanError("the following arguments are required: --tasks") }
    }
}
