// Deadlines are written in LMS posts, not in the calendar. The agent reads them (skill `school-posts`, read-only) and answers with ONE
// fenced JSON array; this file is the strict, pure half. The model can misread a date, and a post can try to talk to it, so nothing in
// a reply is believed because it is there: a reply must hold exactly one fenced block that is a list, and every object must pass
// the checks below or it is dropped (the number dropped is returned, for the log). A course address handed back to the agent must be
// a course page on the Moodle host (never a quiz or an assignment), a post address must be a forum or course page on that host, the
// dates must exist and make sense next to each other, and every item keeps the words it was read from (`quote`) so the card can
// say "from a post, check it". The planning of the day's work (which course next, since when) is here too, as a pure function.
import Foundation

public enum LMSPosts {
    public struct Course: Codable, Equatable, Sendable {
        public var name: String
        public var url: String

        public init(name: String, url: String) { (self.name, self.url) = (name, url) }
    }

    /// A thing teachers added to a course (slides, a reading, a notebook). It has no date, so it is not for the agenda: it is told once, in a
    /// note of the vault, and the address is a page of the course (the material's own link is never opened by the agent).
    public struct Material: Codable, Equatable, Sendable {
        public var id: String
        public var course: String
        public var title: String
        public var url: String
        /// The day it was added or changed, `YYYY-MM-DD`.
        public var posted: String
        public var quote: String
        public var firstSeen: Date

        public init(id: String, course: String, title: String, url: String, posted: String, quote: String, firstSeen: Date) {
            (self.id, self.course, self.title, self.url, self.posted, self.quote, self.firstSeen) = (id, course, title, url, posted, quote, firstSeen)
        }
    }

    /// What survived the checks, and how many objects (or list entries over the cap) did not.
    public struct Parsed<T: Sendable>: Sendable {
        public var values: [T]
        public var dropped: Int
    }

    public enum Failure: Error, Equatable, Sendable { case noBlock, notAList }

    /// The work of a day: read the course list, or scan one course for the posts since a day.
    public enum Step: Equatable, Sendable {
        case list
        case scan(Course, since: String)

        /// What a failure of this step is counted under.
        public var key: String {
            switch self {
            case .list: "list"
            case .scan(let course, _): course.url
            }
        }
    }

    public static let maxCourses = 40, maxItems = 60
    /// The course list is read again after this many days (a new term).
    public static let listDays = 7
    /// A course never scanned before is read back this far (the user chose a daily scan, no backfill).
    public static let firstLookbackDays = 1

    // MARK: what is asked

    public static let listPrompt = "MODE: list\nUse the school-posts skill."

    /// `course` has passed `courses(in:host:)`, `since` and `today` are days (`YYYY-MM-DD`).
    public static func scanPrompt(_ course: Course, since: String, today: String) -> String {
        "MODE: scan\nCOURSE: \(course.url)\nSINCE: \(since)\nTODAY: \(today)\nUse the school-posts skill."
    }

    // MARK: the plan

    /// What to do next today, or nil when the day's work is done. The list comes first (when there is none, or it is `listDays` old, or
    /// it was empty before today);
    /// then each course whose last good scan is not today, in list order, since that scan (or `firstLookbackDays` ago).
    /// `skip` holds the keys of steps that failed too often today.
    public static func next(courses: [Course], coursesDay: String, scanned: [String: String], today: String,
                            skip: Set<String> = []) -> Step? {
        let utc = calendar(TimeZone(identifier: "UTC")!)
        guard let now = stamp(today, utc)?.date else { return nil }
        let listAge = stamp(coursesDay, utc).map { utc.dateComponents([.day], from: $0.date, to: now).day ?? 0 }
        // No list, or a week old; or an empty one read before today (read today and still empty: tomorrow, not every tick).
        if (listAge ?? listDays) >= listDays || (courses.isEmpty && coursesDay != today), !skip.contains(Step.list.key) { return .list }
        let first = utc.date(byAdding: .day, value: -firstLookbackDays, to: now).map { day($0, utc) } ?? today
        for course in courses where scanned[course.url] != today && !skip.contains(course.url) {
            // A last scan in the future (a clock set back) reads from yesterday, like a new course.
            let since = scanned[course.url].flatMap { stamp($0, utc) != nil && $0 <= today ? $0 : nil } ?? first
            return .scan(course, since: since)
        }
        return nil
    }

    // MARK: what is accepted

    /// The courses of a `list` reply: a name, and the course page's address (`https://<host>/course/view.php?id=<number>` and
    /// nothing else, so the agent is never pointed at another page). The same address twice: the first.
    public static func courses(in reply: String, host: String) -> Result<Parsed<Course>, Failure> {
        list(in: reply).map { entries in
            var out: [Course] = [], seen = Set<String>(), dropped = max(0, entries.count - maxCourses)
            for entry in entries.prefix(maxCourses) {
                guard let o = entry as? [String: Any], let name = line(o["name"], max: 120), let url = coursePage(o["url"], host: host),
                      seen.insert(url).inserted else {
                    dropped += 1
                    continue
                }
                out.append(Course(name: name, url: url))
            }
            return Parsed(values: out, dropped: dropped)
        }
    }

    /// The agenda items of a `scan` reply. `today` is the moment of the run (its day in `zone` counts): a post dated after that day is a
    /// misreading. `due` is `YYYY-MM-DDTHH:MM`, or a day (`YYYY-MM-DD`) that stands for the end of that day; `null` has no place in an
    /// agenda and is dropped. Two objects with one id (same course and title): the one from the later post.
    public static func items(in reply: String, host: String, today: Date, zone: TimeZone, now: Date) -> Result<Parsed<AgendaItem>, Failure> {
        let cal = calendar(zone), start = cal.startOfDay(for: today)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: start) ?? start
        let oldest = cal.date(byAdding: .day, value: -400, to: start) ?? start
        let stampNow = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        return list(in: reply).map { entries in
            var best: [String: (posted: Date, item: AgendaItem)] = [:], dropped = max(0, entries.count - maxItems)
            for entry in entries.prefix(maxItems) {
                if (entry as? [String: Any])?["kind"] as? String == "material" { continue }  // `materials(in:)` reads those
                guard let o = entry as? [String: Any], let course = line(o["course"], max: 80), let title = line(o["title"], max: 120),
                      let quote = line(o["quote"], max: 120), let url = postLink(o["post_url"], host: host), let kind = kind(o["kind"]),
                      let posted = (o["posted"] as? String).flatMap({ stamp($0, cal) }), !posted.hasTime,
                      let due = (o["due"] as? String).flatMap({ stamp($0, cal) }), case let postedDay = cal.startOfDay(for: posted.date),
                      postedDay < tomorrow, postedDay >= oldest, due.date >= postedDay,
                      due.date <= cal.date(byAdding: .day, value: 731, to: postedDay) ?? postedDay else {
                    dropped += 1
                    continue
                }
                let id = "lms:" + slug(course) + ":" + slug(title)
                if let kept = best[id] {
                    dropped += 1  // the older of the two is dropped, whichever came first
                    if kept.posted >= postedDay { continue }
                }
                best[id] = (postedDay, AgendaItem(id: id, title: title, course: course, kind: kind, when: due.date, source: .lms, url: url,
                                                    quote: quote, firstSeen: stampNow))
            }
            return Parsed(values: best.values.map(\.item).sorted { ($0.when, $0.id) < ($1.when, $1.id) }, dropped: dropped)
        }
    }

    /// The learning materials of a `scan` reply: the objects whose `kind` is `material` (the others are `items`'). A material has no due
    /// date (`due` must be null or absent) and a day it was added; its address is the post's when that passes `postLink`, else `page`, the
    /// course page the run was sent to. Same course and title: one, the later day.
    public static func materials(in reply: String, host: String, page: String, today: Date, zone: TimeZone, now: Date) -> Result<Parsed<Material>, Failure> {
        let cal = calendar(zone), start = cal.startOfDay(for: today)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: start) ?? start
        let oldest = cal.date(byAdding: .day, value: -400, to: start) ?? start
        let stampNow = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        return list(in: reply).map { entries in
            var best: [String: Material] = [:], dropped = 0
            for entry in entries.prefix(maxItems) {
                guard let o = entry as? [String: Any], o["kind"] as? String == "material" else { continue }
                guard let course = line(o["course"], max: 80), let title = line(o["title"], max: 120), let quote = line(o["quote"], max: 120),
                      o["due"] == nil || o["due"] is NSNull,
                      let posted = o["posted"] as? String, let when = stamp(posted, cal), !when.hasTime,
                      when.date < tomorrow, when.date >= oldest else {
                    dropped += 1
                    continue
                }
                let id = "lms-material:" + slug(course) + ":" + slug(title)
                if let kept = best[id] {
                    dropped += 1
                    if kept.posted >= posted { continue }
                }
                best[id] = Material(id: id, course: course, title: title, url: postLink(o["post_url"], host: host) ?? page, posted: posted,
                                    quote: quote, firstSeen: stampNow)
            }
            return Parsed(values: best.values.sorted { $0.posted != $1.posted ? $0.posted > $1.posted : $0.id < $1.id }, dropped: dropped)  // newest first
        }
    }

    /// Does the agent say, outside the block, that it could not read everything? The skill says to answer without a block then; this is the
    /// net for a reply that still has one (the run of 2026-10-22 said "that request was blocked" and answered `[]`, and `[]` counted as
    /// "nothing new"). Only the words around the block count: a post can quote anything.
    public static func incomplete(_ reply: String) -> Bool {
        let parts = reply.components(separatedBy: "```")
        let prose = (parts.count == 3 ? [parts[0], parts[2]] : parts).joined(separator: " ").lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return ["incomplete", "blocked", "denied", "refused", "couldn't", "could not", "can't", "cannot", "unable to", "not able to",
                "didn't finish", "did not finish"].contains { prose.contains($0) }
    }

    // MARK: the pieces

    /// The JSON list inside the reply's ONE fenced block. No block, two blocks, or a block that is not a list: a failure.
    static func list(in reply: String) -> Result<[Any], Failure> {
        let parts = reply.components(separatedBy: "```")
        guard parts.count == 3, parts[1].lowercased().hasPrefix("json") else { return .failure(.noBlock) }
        guard let list = (try? JSONSerialization.jsonObject(with: Data(parts[1].dropFirst(4).utf8))) as? [Any] else { return .failure(.notAList) }
        return .success(list)
    }

    /// One line of plain text: control and format characters (a right-to-left override) and any run of white space become one
    /// space; nil when empty or not a string; cut at `max` characters.
    static func line(_ any: Any?, max: Int) -> String? {
        guard let s = any as? String else { return nil }
        let words = s.split { c in
            c.isWhitespace || c.unicodeScalars.contains { [.control, .format].contains($0.properties.generalCategory) }
        }
        let text = words.joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(max))
    }

    /// An https address on the Moodle host `host`: default port, no credentials, ASCII, no white space, at most 500 characters.
    private static func onHost(_ any: Any?, host: String) -> URL? {
        guard let s = any as? String, s.count <= 500, s.allSatisfy({ $0.isASCII && !$0.isWhitespace }), let url = URL(string: s),
              url.scheme == "https", url.user() == nil, url.password() == nil, url.port == nil || url.port == 443,
              url.host()?.lowercased() == host.lowercased(), url.fragment == nil else { return nil }
        return url
    }

    /// `https://<host>/course/view.php?id=123`: the only address a run is ever sent to.
    static func coursePage(_ any: Any?, host: String) -> String? {
        guard let url = onHost(any, host: host), url.path() == "/course/view.php", let query = url.query(percentEncoded: true),
              query.hasPrefix("id="), (4...12).contains(query.count), query.dropFirst(3).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return "https://\(host.lowercased())/course/view.php?\(query)"
    }

    /// A forum or course page of the host. Never a quiz, an assignment or anything else: Open would put it in the user's browser.
    static func postLink(_ any: Any?, host: String) -> String? {
        guard let url = onHost(any, host: host), url.path().hasPrefix("/mod/forum/") || url.path().hasPrefix("/course/") else { return nil }
        return url.absoluteString
    }

    private static func kind(_ any: Any?) -> AgendaItem.Kind? {
        switch any as? String {
        case "deadline": .deadline
        case "exam": .exam
        case "event": .event
        default: nil
        }
    }

    private static func slug(_ s: String) -> String {
        String(s.lowercased().split { !($0.isLetter || $0.isNumber) }.joined(separator: "-").prefix(100))
    }

    // MARK: days

    static func calendar(_ zone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }

    static func day(_ date: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func number(_ s: Substring) -> Int? { s.allSatisfy { $0.isASCII && $0.isNumber } ? Int(s) : nil }

    /// `2026-10-23T23:59` or `2026-10-23` (the end of that day: 23:59) in `cal`'s zone; nil when the day or the time does not exist
    /// (30 February, 02:30 in a spring-forward gap come back as another moment). `hasTime` says which of the two it was.
    static func stamp(_ s: String, _ cal: Calendar) -> (date: Date, hasTime: Bool)? {
        let halves = s.split(separator: "T", omittingEmptySubsequences: false)
        guard halves.count <= 2 else { return nil }
        let ymd = halves[0].split(separator: "-", omittingEmptySubsequences: false)
        guard ymd.count == 3, ymd[0].count == 4, ymd[1].count == 2, ymd[2].count == 2,
              let y = number(ymd[0]), let m = number(ymd[1]), let d = number(ymd[2]) else { return nil }
        var h = 23, minute = 59
        if halves.count == 2 {
            let hm = halves[1].split(separator: ":", omittingEmptySubsequences: false)
            guard hm.count == 2, hm[0].count == 2, hm[1].count == 2, let hh = number(hm[0]), let mm = number(hm[1]) else { return nil }
            (h, minute) = (hh, mm)
        }
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: minute)) else { return nil }
        let back = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard back.year == y, back.month == m, back.day == d, back.hour == h, back.minute == minute else { return nil }
        return (date, halves.count == 2)
    }
}
