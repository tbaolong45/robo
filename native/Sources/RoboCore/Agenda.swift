// What is coming up, as one list: deadlines, exams, meetings and opportunities from the Outlook feed (`ics`), the LMS posts
// (`lms`), the study ledger (`ledger`) and the radar (`radar`). Pure: the clock comes in as an argument, and the list is stored
// as JSON (`agenda.json`) by the caller. Each source replaces only its own items (`merge`), so a fresh calendar fetch never
// touches the exams of the ledger.
import Foundation

public struct AgendaItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case deadline, exam, event, opportunity }
    public enum Source: String, Codable, Sendable { case ics, lms, ledger, radar }

    /// Stable for the same thing across fetches (see `Agenda.fromICS` and `Agenda.ledgerExams` for the ids they make).
    public var id: String
    public var title: String
    public var course: String?
    public var kind: Kind
    public var when: Date
    public var source: Source
    public var url: String?
    /// The words behind the item: topics of an exam, the sentence of an LMS post it was read from.
    public var quote: String?
    /// A class of a series: shown in the agenda, never reminded.
    public var recurring: Bool
    /// When this app first saw the item; kept while the id lives on.
    public var firstSeen: Date
    /// True once `when` moved after the item was first seen.
    public var changed: Bool

    public init(id: String, title: String, course: String? = nil, kind: Kind, when: Date, source: Source, url: String? = nil,
                quote: String? = nil, recurring: Bool = false, firstSeen: Date, changed: Bool = false) {
        (self.id, self.title, self.course, self.kind, self.when, self.source) = (id, title, course, kind, when, source)
        (self.url, self.quote, self.recurring, self.firstSeen, self.changed) = (url, quote, recurring, firstSeen, changed)
    }
}

public enum Agenda {
    /// What a `merge` changed in one source's items.
    public struct Change: Equatable, Sendable {
        public enum Kind: String, Sendable { case new, moved, removed }
        public var kind: Kind
        /// The fresh item (`new`, `moved`) or the old one that vanished (`removed`).
        public var item: AgendaItem
        /// `moved`: the time it had before.
        public var was: Date?

        public init(_ kind: Kind, _ item: AgendaItem, was: Date? = nil) { (self.kind, self.item, self.was) = (kind, item, was) }
    }

    /// An item more than this long past is dropped.
    public static let keepPast: TimeInterval = 86_400

    /// `fresh` (what `source` reports now) replaces the old items of that source; the other sources' items stay. An item whose
    /// id lives on keeps its `firstSeen` and `changed`, and if its `when` moved it becomes `changed` and a `.moved` change; a
    /// new id is `.new`; an old one that is gone is `.removed` (unless it had already passed, which is just the window moving).
    /// Items over a day in the past are dropped from the list and from the changes. Sorted by time, then id.
    public static func merge(old: [AgendaItem], fresh: [AgendaItem], source: AgendaItem.Source, now: Date) -> (items: [AgendaItem], changes: [Change]) {
        let keep = now.addingTimeInterval(-keepPast)
        var before: [String: AgendaItem] = [:]
        for item in old where item.source == source { before[item.id] = item }
        var items = old.filter { $0.source != source && $0.when >= keep }
        var changes: [Change] = []
        var seen = Set<String>()
        for var item in fresh where item.source == source && item.when >= keep && seen.insert(item.id).inserted {
            if let was = before[item.id] {
                item.firstSeen = was.firstSeen
                item.changed = was.changed
                if item.when != was.when {
                    item.changed = true
                    changes.append(Change(.moved, item, was: was.when))
                }
            } else {
                changes.append(Change(.new, item))
            }
            items.append(item)
        }
        for item in before.values where !seen.contains(item.id) && item.when >= keep { changes.append(Change(.removed, item)) }
        items.sort { ($0.when, $0.id) < ($1.when, $1.id) }
        changes.sort { ($0.item.when, $0.item.id, $0.kind.rawValue) < ($1.item.when, $1.item.id, $1.kind.rawValue) }
        return (items, changes)
    }

    // MARK: storage

    /// JSON, ISO 8601 in UTC, sorted keys: the same list always gives the same bytes.
    public static func encode(_ items: [AgendaItem]) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return (try? encoder.encode(items)) ?? Data("[]".utf8)
    }

    /// The items of a file `encode` wrote. An item that cannot be read is dropped, not the whole list; a file that is not a list gives [].
    public static func decode(_ data: Data) -> [AgendaItem] {
        struct Lossy: Decodable {
            let item: AgendaItem?
            init(from decoder: Decoder) throws { item = try? AgendaItem(from: decoder) }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([Lossy].self, from: data)) ?? []).compactMap(\.item)
    }

    // MARK: from the Outlook / Moodle feed

    /// The feed's events as agenda items. The id is the UID, so a deadline that Moodle moves is the same item (`merge` sees
    /// `moved`); an occurrence of a series is `uid@start` (every class shares one UID). An all-day event that is no deadline
    /// or exam (a holiday, "out of office") is left out: there is no time to remind at. Two events with one id: the first.
    public static func fromICS(_ events: [ICSEvent], now: Date) -> [AgendaItem] {
        let stamp = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        var seen = Set<String>()
        var items: [AgendaItem] = []
        for e in events {
            let kind = classify(e.summary) ?? classify(e.categories) ?? .event
            if e.allDay, kind == .event { continue }
            let id = e.isRecurring ? "\(e.uid)@\(Int(e.start.timeIntervalSince1970))" : e.uid
            guard seen.insert(id).inserted else { continue }
            let title = e.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let category = e.categories.trimmingCharacters(in: .whitespacesAndNewlines)
            // Outlook's own colour labels ("Blue category") are not a course.
            let course = !category.isEmpty && !category.hasSuffix(" category") ? String(category.prefix(80)) : nil
            items.append(AgendaItem(id: id, title: title.isEmpty ? "(untitled)" : title, course: course, kind: kind, when: e.start,
                                    source: .ics, url: link(in: e.description) ?? link(in: e.location), recurring: e.isRecurring,
                                    firstSeen: stamp))
        }
        return items
    }

    private static let strongWords: Set<String> = ["due", "deadline", "deadlines", "submit", "submission", "submissions", "closes"]
    private static let examWords: Set<String> = ["exam", "exams", "midterm", "midterms"]
    private static let weakWords: Set<String> = ["quiz", "quizzes", "assignment", "assignments", "homework", "coursework"]

    /// What a title or category says it is: nil when no word of the (deliberately small, English) lists is in it. "Quiz 1
    /// opens" is an event; "is due" / "deadline" / "submission" / "closes" win over "exam" ("exam registration deadline");
    /// "exam" / "midterm" over the quiz-and-assignment words.
    static func classify(_ text: String) -> AgendaItem.Kind? {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        if words.contains("opens") { return .event }
        if !words.isDisjoint(with: strongWords) { return .deadline }
        if !words.isDisjoint(with: examWords) { return .exam }
        if !words.isDisjoint(with: weakWords) { return .deadline }
        return nil
    }

    /// The first https link in `text`, without the punctuation a sentence puts after it.
    static func link(in text: String) -> String? {
        guard let r = text.range(of: #"https://[^\s<>"'\\)\]]{4,500}"#, options: .regularExpression) else { return nil }
        return String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
    }

    // MARK: from the study ledger

    /// The exams of `study.md`: the lines under `## Exams`, `- 2026-10-11 · MATH201 Linear Algebra midterm · 2026-10-20 09:00`
    /// plus an optional `· topics: eigenvalues; SVD` (kept in `quote`). The first date is the day it was logged; the exam time
    /// is in `zone`, and 09:00 when the line has none. A line that does not fit (a missing part, a day that does not exist, a
    /// time that is no time) is skipped. The id is the subject, so a moved exam (the line is patched) is `moved`, not new;
    /// the same subject twice keeps the later logged line.
    public static func ledgerExams(from studyMarkdown: String, zone: TimeZone, now: Date) -> [AgendaItem] {
        let stamp = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        var inside = false
        var found: [String: (logged: String, item: AgendaItem)] = [:]
        for raw in studyMarkdown.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                inside = line.hasPrefix("## ") && line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == "exams"
                continue
            }
            guard inside, line.hasPrefix("-") else { continue }
            let parts = line.dropFirst().split(separator: "·", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3, ymd(parts[0]) != nil, !parts[1].isEmpty, let when = examTime(parts[2], cal) else { continue }
            let subject = String(parts[1].prefix(200))
            let id = "ledger:" + slug(subject)
            if let kept = found[id], kept.logged >= parts[0] { continue }
            let topics = parts.dropFirst(3).first { $0.lowercased().hasPrefix("topics:") }.map { String($0.prefix(300)) }
            let code = subject.split(separator: " ").first.map(String.init) ?? ""
            let course = code.range(of: #"^[A-Z]{2,5}\d{2,4}[A-Z]?$"#, options: .regularExpression) != nil ? code : nil
            found[id] = (parts[0], AgendaItem(id: id, title: subject, course: course, kind: .exam, when: when, source: .ledger,
                                              quote: topics, firstSeen: stamp))
        }
        return found.values.map(\.item).sorted { ($0.when, $0.id) < ($1.when, $1.id) }
    }

    /// `2026-10-20` as (year, month, day); nil when it is not a day that exists.
    private static func ymd(_ s: String) -> (Int, Int, Int)? {
        let p = s.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              (1970...2200).contains(y), (1...12).contains(m), (1...monthLength(y, m)).contains(d) else { return nil }
        return (y, m, d)
    }

    /// `2026-10-20 09:00`, `2026-10-20 9:00` or `2026-10-20` (09:00); anything after the time is ignored (`09:00 (Hall B)`).
    private static func examTime(_ s: String, _ cal: Calendar) -> Date? {
        let words = s.split(separator: " ", maxSplits: 2).map(String.init)
        guard let day = words.first, let (y, m, d) = ymd(day) else { return nil }
        var hour = 9, minute = 0
        if words.count > 1 {
            let t = words[1].split(separator: ":", omittingEmptySubsequences: false)
            guard t.count == 2, let h = Int(t[0]), let mi = Int(t[1]), (0..<24).contains(h), (0..<60).contains(mi) else { return nil }
            (hour, minute) = (h, mi)
        }
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))
    }

    private static func slug(_ s: String) -> String {
        s.lowercased().split { !($0.isLetter || $0.isNumber) }.joined(separator: "-")
    }
}
