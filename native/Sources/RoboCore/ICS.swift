// A calendar feed (RFC 5545 text, from Moodle or an Outlook "publish calendar" link) as plain events. Pure: the text and
// the clock come in as arguments. The feed is untrusted: a bad line or event is skipped and counted, never fatal, and every
// size is capped (input bytes, line length, events, occurrences per rule, work per parse).
//
// Moodle exports UTC times (`...Z`) and no RRULE. Outlook exports TZID (often a Windows name such as "W. Europe Standard
// Time"), RRULE, EXDATE, all-day events and a VTIMEZONE block (ignored: the zone names are mapped instead).
// Recurrence: only FREQ=DAILY|WEEKLY with INTERVAL, BYDAY, COUNT, UNTIL (and WKST) is expanded; anything else (MONTHLY,
// YEARLY, BYSETPOS...) is skipped and counted. Occurrences keep the wall-clock time of their DTSTART across DST changes.
import Foundation

/// One event of a feed, or one occurrence of a recurring one.
public struct ICSEvent: Equatable, Sendable {
    public var uid: String
    public var summary: String
    public var start: Date
    /// DTEND (exclusive for an all-day event); nil when the feed has none.
    public var end: Date?
    public var allDay: Bool
    public var location: String
    public var description: String
    /// CATEGORIES, unescaped. Moodle puts the course name here.
    public var categories: String
    public var lastModified: Date?
    public var sequence: Int?
    /// True for an expanded occurrence of a series and for a modified single occurrence of one (a class).
    public var isRecurring: Bool

    public init(uid: String, summary: String, start: Date, end: Date? = nil, allDay: Bool = false, location: String = "",
                description: String = "", categories: String = "", lastModified: Date? = nil, sequence: Int? = nil,
                isRecurring: Bool = false) {
        (self.uid, self.summary, self.start, self.end, self.allDay) = (uid, summary, start, end, allDay)
        (self.location, self.description, self.categories) = (location, description, categories)
        (self.lastModified, self.sequence, self.isRecurring) = (lastModified, sequence, isRecurring)
    }
}

public enum ICS {
    public static let maxEvents = 5000  // events returned (and VEVENTs read)
    public static let maxOccurrences = 200  // occurrences expanded from one rule
    static let maxBytes = 4_000_000  // input read; the rest is ignored
    static let maxLine = 65_536  // bytes of one unfolded line
    static let maxSteps = 20_000  // days or weeks one rule walks
    static let stepBudget = 1_000_000  // days or weeks all rules of one parse walk

    /// Windows zone names as Outlook writes them in TZID, to IANA ids. An unknown name falls back to the caller's zone.
    static let windowsZones: [String: String] = [
        "W. Europe Standard Time": "Europe/Berlin", "Central Europe Standard Time": "Europe/Budapest",
        "Romance Standard Time": "Europe/Paris", "GMT Standard Time": "Europe/London",
        "Eastern Standard Time": "America/New_York", "Central Standard Time": "America/Chicago",
        "Mountain Standard Time": "America/Denver", "Pacific Standard Time": "America/Los_Angeles",
        "Arabian Standard Time": "Asia/Dubai", "India Standard Time": "Asia/Kolkata",
        "China Standard Time": "Asia/Shanghai", "Tokyo Standard Time": "Asia/Tokyo", "Korea Standard Time": "Asia/Seoul",
        "Singapore Standard Time": "Asia/Singapore", "SE Asia Standard Time": "Asia/Bangkok",
        "AUS Eastern Standard Time": "Australia/Sydney",
    ]

    /// The events of `text` that start from a day before `now` to `horizonDays` after it (a one-off event outside that window
    /// is not returned; a series gives its occurrences inside it), sorted by start. `zone` is the zone for floating times, for
    /// all-day events and for a TZID this parser does not know (the feed's X-WR-TIMEZONE, when it names a known zone, comes first).
    /// `skipped` counts the VEVENTs that gave nothing because they could not be read: no usable DTSTART, never closed, an RRULE
    /// beyond the simple forms, or over the caps. A cancelled event and an event outside the window are not "skipped".
    public static func parse(_ text: String, now: Date, horizonDays: Int = 30, zone: TimeZone = .current) -> (events: [ICSEvent], skipped: Int) {
        parse(bytes: Array(text.utf8.prefix(maxBytes)), now: now, horizonDays: horizonDays, zone: zone)
    }

    /// The same for the bytes of a download. Prefer it to decoding the bytes yourself: a fold that falls inside a multi-byte
    /// character is undone here before the text is decoded.
    public static func parse(_ data: Data, now: Date, horizonDays: Int = 30, zone: TimeZone = .current) -> (events: [ICSEvent], skipped: Int) {
        parse(bytes: Array(data.prefix(maxBytes)), now: now, horizonDays: horizonDays, zone: zone)
    }

    static func parse(bytes: [UInt8], now: Date, horizonDays: Int, zone: TimeZone) -> (events: [ICSEvent], skipped: Int) {
        var skipped = 0
        var feedZone: TimeZone?
        var raws: [Raw] = []
        var stack: [String] = []
        var current: Raw?

        for line in unfold(bytes) {
            guard let (name, params, value) = split(line) else { continue }
            switch name {
            case "BEGIN":
                let component = value.uppercased()
                if component == "VEVENT" {
                    if current != nil { skipped += 1 }  // the previous one never ended
                    if let i = stack.lastIndex(of: "VEVENT") { stack.removeSubrange(i...) }
                    current = Raw()
                }
                if stack.count < 16 { stack.append(component) }
            case "END":
                let component = value.uppercased()
                if component == "VEVENT", let raw = current {
                    if raws.count < maxEvents { raws.append(raw) } else { skipped += 1 }
                    current = nil
                } else if component == "VCALENDAR", current != nil {
                    skipped += 1
                    current = nil
                }
                if let i = stack.lastIndex(of: component) { stack.removeSubrange(i...) }
            default:
                if stack.last == "VEVENT" {
                    current?.take(name, params, value)
                } else if name == "X-WR-TIMEZONE", stack.last == "VCALENDAR", feedZone == nil {
                    feedZone = zoneFor(value)
                }
            }
        }
        if current != nil { skipped += 1 }

        let home = feedZone ?? zone
        let ctx = Ctx()
        let lo = now.addingTimeInterval(-86_400)
        let hi = now.addingTimeInterval(Double(min(max(horizonDays, 0), 3650)) * 86_400)

        // The instants of a series that a RECURRENCE-ID event replaces (or cancels).
        var replaced: [String: Set<Int>] = [:]
        for raw in raws {
            if let id = raw.recurrenceID, let at = date(id.value, id.params, home, ctx) {
                replaced[raw.uid, default: []].insert(Int(at.date.timeIntervalSince1970))
            }
        }

        var events: [ICSEvent] = []
        var steps = stepBudget
        for raw in raws where raw.status != "CANCELLED" {
            guard let begin = raw.dtstart.flatMap({ date($0.value, $0.params, home, ctx) }),
                  raw.recurrenceID == nil || raw.recurrenceID.flatMap({ date($0.value, $0.params, home, ctx) }) != nil
            else { skipped += 1; continue }
            let finish = raw.dtend.flatMap { date($0.value, $0.params, home, ctx) }?.date
            let length = finish.map { $0.timeIntervalSince(begin.date) }.flatMap { $0 >= 0 ? $0 : nil }
            func make(_ start: Date, recurring: Bool) -> ICSEvent {
                ICSEvent(uid: raw.identity, summary: raw.summary, start: start, end: length.map { start.addingTimeInterval($0) },
                         allDay: begin.allDay, location: raw.location, description: raw.description, categories: raw.categories,
                         lastModified: raw.lastModified.flatMap { date($0, [:], home, ctx)?.date }, sequence: raw.sequence, isRecurring: recurring)
            }
            if raw.recurrenceID != nil {  // a modified single occurrence: the series' own one is dropped below
                if begin.date >= lo, begin.date <= hi, events.count < maxEvents { events.append(make(begin.date, recurring: true)) }
            } else if let text = raw.rrule {
                guard steps > 0, let rule = Rule(text, zone: begin.zone, ctx: ctx) else { skipped += 1; continue }
                var drop = replaced[raw.uid] ?? []
                for ex in raw.exdates {
                    for part in ex.value.split(separator: ",").prefix(1000) {
                        if let at = date(String(part), ex.params, home, ctx) { drop.insert(Int(at.date.timeIntervalSince1970)) }
                    }
                }
                for at in rule.occurrences(from: begin.date, zone: begin.zone, lo: lo, hi: hi, ctx: ctx, steps: &steps)
                where !drop.contains(Int(at.timeIntervalSince1970)) && events.count < maxEvents {
                    events.append(make(at, recurring: true))
                }
            } else if begin.date >= lo, begin.date <= hi, events.count < maxEvents {
                events.append(make(begin.date, recurring: false))
            }
        }
        events.sort { ($0.start, $0.uid) < ($1.start, $1.uid) }
        return (events, skipped)
    }

    // MARK: lines

    /// The logical lines of a feed: CRLF, LF and CR end a line; a line that starts with a space or tab continues the previous
    /// one. Folding is undone on bytes (a fold may fall inside a multi-byte character) and decoded after.
    static func unfold(_ input: [UInt8]) -> [String] {
        var bytes = input
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        var lines: [[UInt8]] = []
        var i = 0
        while i < bytes.count {
            var j = i
            while j < bytes.count, bytes[j] != 10, bytes[j] != 13 { j += 1 }
            if j > i {
                if (bytes[i] == 32 || bytes[i] == 9), !lines.isEmpty {
                    if lines[lines.count - 1].count < maxLine { lines[lines.count - 1].append(contentsOf: bytes[(i + 1)..<j]) }
                } else {
                    lines.append(Array(bytes[i..<min(j, i + maxLine)]))
                }
            }
            i = j + 1  // a CR LF pair leaves an empty line behind, which is skipped above
        }
        return lines.map { String(decoding: $0, as: UTF8.self) }
    }

    /// `NAME;PARAM=value;PARAM="a;b":value` as (NAME in capitals, parameters with capital names and no quotes, value); nil
    /// without a colon outside quotes.
    static func split(_ line: String) -> (name: String, params: [String: String], value: String)? {
        let b = Array(line.utf8)
        var quoted = false
        var colon = -1
        var semicolons: [Int] = []
        for (i, c) in b.enumerated() {
            if c == 34 {
                quoted.toggle()
            } else if !quoted {
                if c == 58 { colon = i; break }
                if c == 59 { semicolons.append(i) }
            }
        }
        guard colon > 0 else { return nil }
        func text(_ a: Int, _ z: Int) -> String { String(decoding: b[a..<z], as: UTF8.self) }
        let name = text(0, semicolons.first ?? colon).trimmingCharacters(in: .whitespaces).uppercased()
        guard !name.isEmpty else { return nil }
        var params: [String: String] = [:]
        let edges = semicolons + [colon]
        for (a, z) in zip(edges, edges.dropFirst()) {
            let part = text(a + 1, z)
            guard let eq = part.firstIndex(of: "=") else { continue }
            params[part[..<eq].uppercased()] = part[part.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return (name, params, text(colon + 1, b.count))
    }

    /// TEXT value escapes: \n \N newline, \, \; \\ the character itself.
    static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var escaped = false
        for ch in s {
            if escaped {
                out.append(ch == "n" || ch == "N" ? "\n" : ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// The properties of one VEVENT, as text: dates are resolved once the feed's own zone is known.
    struct Raw {
        var uid = "", summary = "", location = "", description = "", categories = "", status = ""
        var dtstart, dtend, recurrenceID: (value: String, params: [String: String])?
        var rrule: String?
        var exdates: [(value: String, params: [String: String])] = []
        var lastModified: String?
        var sequence: Int?

        /// The UID, or (a feed without one) a stand-in made of the subject and start, so two events never share an empty id.
        var identity: String { uid.isEmpty ? "nouid:\(summary)@\(dtstart?.value ?? "")" : uid }

        mutating func take(_ name: String, _ params: [String: String], _ value: String) {
            switch name {
            case "UID": if uid.isEmpty { uid = String(value.trimmingCharacters(in: .whitespaces).prefix(300)) }
            case "SUMMARY": summary = String(unescape(value).prefix(300))
            case "LOCATION": location = String(unescape(value).prefix(300))
            case "DESCRIPTION": description = String(unescape(value).prefix(4000))
            case "CATEGORIES": categories = String((categories.isEmpty ? unescape(value) : categories + ", " + unescape(value)).prefix(300))
            case "STATUS": status = value.trimmingCharacters(in: .whitespaces).uppercased()
            case "DTSTART": dtstart = (value, params)
            case "DTEND": dtend = (value, params)
            case "RECURRENCE-ID": recurrenceID = (value, params)
            case "RRULE": rrule = value
            case "EXDATE": if exdates.count < 1000 { exdates.append((value, params)) }
            case "LAST-MODIFIED": lastModified = value
            case "SEQUENCE": sequence = Int(value.trimmingCharacters(in: .whitespaces))
            default: break
            }
        }
    }

    // MARK: dates and zones

    /// Calendars by zone, made once per parse.
    final class Ctx {
        private var cache: [String: Calendar] = [:]
        func calendar(_ zone: TimeZone) -> Calendar {
            if let c = cache[zone.identifier] { return c }
            var c = Calendar(identifier: .gregorian)
            c.timeZone = zone
            cache[zone.identifier] = c
            return c
        }
    }

    /// A zone from an IANA id or a Windows name; nil when unknown.
    static func zoneFor(_ name: String) -> TimeZone? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.count < 100 else { return nil }
        return TimeZone(identifier: windowsZones[n] ?? n)
    }

    /// A DATE (`20261023`) or DATE-TIME (`20261023T100000`, with `Z` for UTC) value. A local time takes the zone of the TZID
    /// parameter, else `fallback`. Nil for anything else, a day that does not exist, or a year outside 1970...2200.
    static func date(_ value: String, _ params: [String: String], _ fallback: TimeZone, _ ctx: Ctx) -> (date: Date, allDay: Bool, zone: TimeZone)? {
        let v = Array(value.trimmingCharacters(in: .whitespaces).utf8)
        let utc = v.last == 90
        let digits = utc ? Array(v.dropLast()) : v
        let allDay = digits.count == 8
        guard allDay || (digits.count == 15 && digits[8] == 84), !(utc && allDay) else { return nil }
        func num(_ at: Int, _ n: Int) -> Int? {
            var r = 0
            for c in digits[at..<(at + n)] {
                guard c >= 48, c <= 57 else { return nil }
                r = r * 10 + Int(c) - 48
            }
            return r
        }
        guard let y = num(0, 4), let m = num(4, 2), let d = num(6, 2), (1970...2200).contains(y), (1...12).contains(m),
              (1...monthLength(y, m)).contains(d) else { return nil }
        var h = 0, mi = 0, s = 0
        if !allDay {
            guard let hh = num(9, 2), let mm = num(11, 2), let ss = num(13, 2), hh < 24, mm < 60, ss <= 60 else { return nil }
            (h, mi, s) = (hh, mm, min(ss, 59))
        }
        if utc {
            let secs = epochDay(y, m, d) * 86_400 + h * 3600 + mi * 60 + s
            return (Date(timeIntervalSince1970: Double(secs)), false, TimeZone(secondsFromGMT: 0)!)
        }
        let zone = params["TZID"].flatMap(zoneFor) ?? fallback
        let parts = DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s)
        return ctx.calendar(zone).date(from: parts).map { ($0, allDay, zone) }
    }

    // MARK: recurrence

    /// A simple RRULE: DAILY or WEEKLY, INTERVAL, BYDAY (no ordinals), COUNT, UNTIL, WKST. Anything else makes `init` fail.
    struct Rule {
        static let weekdays = ["SU": 0, "MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6]
        var weekly = false, interval = 1, wkst = 1
        var count: Int?, until: Date?
        var days: [Int] = []  // 0 = Sunday

        init?(_ text: String, zone: TimeZone, ctx: Ctx) {
            var freq = ""
            for part in text.split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { return nil }
                let value = String(kv[1])
                switch kv[0].uppercased() {
                case "FREQ": freq = value.uppercased()
                case "INTERVAL":
                    guard let n = Int(value), (1...1000).contains(n) else { return nil }
                    interval = n
                case "COUNT":
                    guard let n = Int(value), n >= 1 else { return nil }
                    count = n
                case "UNTIL":
                    guard let u = ICS.date(value, [:], zone, ctx) else { return nil }
                    until = u.allDay ? u.date.addingTimeInterval(86_399) : u.date
                case "WKST":
                    guard let d = Rule.weekdays[value.uppercased()] else { return nil }
                    wkst = d
                case "BYDAY":
                    for token in value.split(separator: ",") {
                        guard let d = Rule.weekdays[token.uppercased()] else { return nil }
                        days.append(d)
                    }
                default: return nil  // BYMONTHDAY, BYSETPOS, BYMONTH, BYHOUR...: not a simple rule
                }
            }
            guard freq == "DAILY" || freq == "WEEKLY" else { return nil }
            weekly = freq == "WEEKLY"
            days = Array(Set(days)).sorted()
        }

        /// The occurrences of the series that starts at `start` (in `zone`, at the same local time every day) that fall in
        /// `lo...hi`, at most `maxOccurrences`. `steps` is the work left for the whole parse. A series with no COUNT jumps
        /// to the window; with a COUNT the days before it are walked (and counted, as the rule says), up to `maxSteps`.
        func occurrences(from start: Date, zone: TimeZone, lo: Date, hi: Date, ctx: Ctx, steps budget: inout Int) -> [Date] {
            let cal = ctx.calendar(zone)
            let local = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
            func day(_ d: Date) -> Int {
                let c = cal.dateComponents([.year, .month, .day], from: d)
                return epochDay(c.year!, c.month!, c.day!)
            }
            let first = day(start)
            let low = day(lo) - 1, high = day(hi) + 1
            var out: [Date] = []
            var seen = 0
            var walked = 0

            /// Takes the day `n` (a candidate occurrence); false once nothing later can count.
            func visit(_ n: Int) -> Bool {
                if n > high { return false }
                if !weekly, !days.isEmpty, !days.contains(dayOfWeek(n)) { return true }
                seen += 1
                if let c = count, seen > c { return false }
                if n < low { return true }
                let (y, m, d) = civilDate(n)
                var parts = local
                (parts.year, parts.month, parts.day) = (y, m, d)
                guard let at = cal.date(from: parts) else { return true }
                if at > hi { return false }
                if let u = until, at > u { return false }
                if at >= lo { out.append(at) }
                return out.count < maxOccurrences
            }

            if !weekly {
                var k = count == nil ? max(0, (low - first) / interval - 1) : 0
                while walked < maxSteps, budget > 0 {
                    walked += 1
                    budget -= 1
                    if !visit(first + k * interval) { break }
                    k += 1
                }
            } else {
                let on = (days.isEmpty ? [dayOfWeek(first)] : days).map { ($0 - wkst + 7) % 7 }.sorted()
                let anchor = first - (dayOfWeek(first) - wkst + 7) % 7  // the first day of the first week
                var w = count == nil ? max(0, (low - anchor) / (7 * interval) - 1) : 0
                weeks: while walked < maxSteps, budget > 0 {
                    walked += 1
                    budget -= 1
                    let base = anchor + w * 7 * interval
                    w += 1
                    if base > high { break }
                    for offset in on where base + offset >= first {
                        if !visit(base + offset) { break weeks }
                    }
                }
            }
            return out
        }
    }
}

/// Days since 1970-01-01 of a Gregorian date (month 1...12).
func epochDay(_ year: Int, _ month: Int, _ day: Int) -> Int {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
}

/// The date of a day number from `epochDay`.
func civilDate(_ days: Int) -> (year: Int, month: Int, day: Int) {
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let month = mp < 10 ? mp + 3 : mp - 9
    return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, doy - (153 * mp + 2) / 5 + 1)
}

/// 0 = Sunday ... 6 = Saturday, for a day number from `epochDay` (1970-01-01 was a Thursday).
func dayOfWeek(_ days: Int) -> Int { ((days + 4) % 7 + 7) % 7 }

func monthLength(_ year: Int, _ month: Int) -> Int {
    if month == 2 { return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28 }
    return [4, 6, 9, 11].contains(month) ? 30 : 31
}
