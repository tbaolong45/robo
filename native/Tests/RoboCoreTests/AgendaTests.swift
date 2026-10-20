// The agenda: merging a source's fresh items into the stored list (new / moved / removed, per source), the JSON file, the
// events of a calendar feed as items (kind, course, link, ids), and the exams of the study ledger.
import Foundation
import Testing
@testable import RoboCore

private let UTC = TimeZone(identifier: "UTC")!
private let VN = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
private let NEW_YORK = TimeZone(identifier: "America/New_York")!

private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ zone: TimeZone = UTC) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

/// Tuesday 2026-10-20, 09:00 in Vietnam (02:00Z).
private let NOW = at(2026, 10, 20, 9, 0, VN)
private let LONG_AGO = at(2026, 10, 1)

private func item(_ id: String, _ when: Date, source: AgendaItem.Source = .ics, kind: AgendaItem.Kind = .deadline, title: String? = nil,
                  firstSeen: Date = NOW, changed: Bool = false) -> AgendaItem {
    AgendaItem(id: id, title: title ?? "Item \(id)", kind: kind, when: when, source: source, firstSeen: firstSeen, changed: changed)
}

private func crlf(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "\r\n") }

/// A Moodle export: three events, one outside the window.
private let MOODLE = crlf(#"""
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Moodle Pty Ltd//NONSGML Moodle Version 2024100702//EN
BEGIN:VEVENT
UID:48113@moodle.uni.example
SUMMARY:Assignment 2: Eigenvalues is due
DESCRIPTION:<p>Upload your solutions as one PDF.</p>\n<p>See <a href="https://moodle.uni.example/mod/assign/view.php?id=7731">Assignment 2</a>\, then submit.</p>
DTSTART:20261023T160000Z
DTEND:20261023T160000Z
CATEGORIES:MATH201 Linear Algebra
END:VEVENT
BEGIN:VEVENT
UID:48121@moodle.uni.example
SUMMARY:Quiz 5: Orthogonality opens
DTSTART:20261026T010000Z
DTEND:20261026T010000Z
CATEGORIES:MATH201 Linear Algebra
END:VEVENT
BEGIN:VEVENT
UID:48155@moodle.uni.example
SUMMARY:MATH201 midterm exam
DTSTART:20261028T020000Z
DTEND:20261028T040000Z
CATEGORIES:MATH201 Linear Algebra
END:VEVENT
END:VCALENDAR
"""#)

/// The same deadline after the teacher moved it two days.
private let MOODLE_EXTENDED = MOODLE.replacingOccurrences(of: "DTSTART:20261023T160000Z\r\nDTEND:20261023T160000Z", with: "DTSTART:20261025T160000Z\r\nDTEND:20261025T160000Z")

/// An Outlook export: a Tuesday lecture series, an all-day holiday, an all-day deadline, a Teams meeting.
private let OUTLOOK = crlf(#"""
BEGIN:VCALENDAR
PRODID:Microsoft Exchange Server 2010
VERSION:2.0
BEGIN:VEVENT
RRULE:FREQ=WEEKLY;COUNT=12;BYDAY=TU
UID:040000008200E00074C5B7101A82E008000000001111
SUMMARY:MATH201 Lecture
DTSTART;TZID=W. Europe Standard Time:20260908T100000
DTEND;TZID=W. Europe Standard Time:20260908T114500
CATEGORIES:Blue category
END:VEVENT
BEGIN:VEVENT
UID:040000008200E00074C5B7101A82E008000000002222
SUMMARY:Reading week
DTSTART;VALUE=DATE:20261102
DTEND;VALUE=DATE:20261107
END:VEVENT
BEGIN:VEVENT
UID:040000008200E00074C5B7101A82E008000000003333
SUMMARY:Thesis outline due
DTSTART;VALUE=DATE:20261030
DTEND;VALUE=DATE:20261031
END:VEVENT
BEGIN:VEVENT
UID:040000008200E00074C5B7101A82E008000000004444
SUMMARY:Project meeting
DTSTART;TZID=W. Europe Standard Time:20261021T153000
DTEND;TZID=W. Europe Standard Time:20261021T161500
DESCRIPTION:Join: https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d.\n\nCall in.
END:VEVENT
END:VCALENDAR
"""#)

/// A study ledger as the study-ledger skill writes it (hermes/skills/school/study-ledger/SKILL.md).
private let LEDGER = """
# Study ledger

## Goals
- 2026-10-11 · Get an A in Linear Algebra (MATH201)

## Exams
- 2026-10-11 · MATH201 Linear Algebra midterm · 2026-10-20 09:00

## Results
- 2026-10-11 · MATH201 quiz 3 · 7/10 (70%)

## Notes
- 2026-10-11 · Prefers 45-min blocks, mornings
"""

@Suite struct AgendaTests {
    // MARK: merge

    @Test func theFirstFetchMakesEveryItemNew() {
        let a = item("a", at(2026, 10, 22)), b = item("b", at(2026, 10, 21))
        let r = Agenda.merge(old: [], fresh: [a, b], source: .ics, now: NOW)
        #expect(r.items == [b, a])  // by time
        #expect(r.changes == [Agenda.Change(.new, b), Agenda.Change(.new, a)])
    }

    @Test func anUnchangedFetchChangesNothingAndKeepsFirstSeen() {
        let old = [item("a", at(2026, 10, 22), firstSeen: LONG_AGO), item("b", at(2026, 10, 21), firstSeen: LONG_AGO)]
        let fresh = [item("a", at(2026, 10, 22)), item("b", at(2026, 10, 21))]  // firstSeen = now on every fetch
        let r = Agenda.merge(old: old, fresh: fresh, source: .ics, now: NOW)
        #expect(r.changes.isEmpty)
        #expect(r.items.map(\.firstSeen) == [LONG_AGO, LONG_AGO])
        #expect(r.items.allSatisfy { !$0.changed })
    }

    @Test func aMovedItemIsChangedAndStaysChangedWhileItsTimeHoldsStill() {
        let old = [item("a", at(2026, 10, 23, 16), firstSeen: LONG_AGO)]
        let moved = Agenda.merge(old: old, fresh: [item("a", at(2026, 10, 25, 16))], source: .ics, now: NOW)
        #expect(moved.items.count == 1 && moved.items[0].changed && moved.items[0].firstSeen == LONG_AGO)
        #expect(moved.items[0].when == at(2026, 10, 25, 16))
        #expect(moved.changes == [Agenda.Change(.moved, moved.items[0], was: at(2026, 10, 23, 16))])
        let again = Agenda.merge(old: moved.items, fresh: [item("a", at(2026, 10, 25, 16))], source: .ics, now: NOW)
        #expect(again.changes.isEmpty && again.items[0].changed && again.items[0].firstSeen == LONG_AGO)
    }

    @Test func aMovedItemTakesTheFreshTitleAndKind() {
        let old = [item("a", at(2026, 10, 23), kind: .event, title: "Old title", firstSeen: LONG_AGO)]
        let r = Agenda.merge(old: old, fresh: [item("a", at(2026, 10, 23), kind: .deadline, title: "New title")], source: .ics, now: NOW)
        #expect(r.items[0].title == "New title" && r.items[0].kind == .deadline && r.items[0].firstSeen == LONG_AGO)
        #expect(r.changes.isEmpty)  // the time did not move
    }

    @Test func anItemThatVanishedIsRemovedAndLeavesTheList() {
        let a = item("a", at(2026, 10, 23)), c = item("c", at(2026, 10, 24))
        let r = Agenda.merge(old: [a, c], fresh: [a], source: .ics, now: NOW)
        #expect(r.items == [a] && r.changes == [Agenda.Change(.removed, c)])
    }

    @Test func anItemThatLeftBecauseItIsPastIsNotReportedRemovedButOneFromHalfADayAgoIs() {
        let old = item("old", NOW.addingTimeInterval(-2 * 86_400)), recent = item("recent", NOW.addingTimeInterval(-12 * 3600))
        let r = Agenda.merge(old: [old, recent], fresh: [], source: .ics, now: NOW)
        #expect(r.items.isEmpty)
        #expect(r.changes == [Agenda.Change(.removed, recent)])
    }

    @Test func theCutoffIsExactlyADay() {
        let edge = item("edge", NOW.addingTimeInterval(-86_400)), over = item("over", NOW.addingTimeInterval(-86_401))
        let r = Agenda.merge(old: [], fresh: [edge, over], source: .ics, now: NOW)
        #expect(r.items.map(\.id) == ["edge"] && r.changes.map(\.item.id) == ["edge"])
    }

    @Test func otherSourcesStayEvenWithTheSameIdAndTheirOldPastItemsGo() {
        let exam = item("ledger:math201", at(2026, 10, 28), source: .ledger, kind: .exam)
        let post = item("p1", at(2026, 10, 30), source: .lms)
        let stale = item("stale", NOW.addingTimeInterval(-3 * 86_400), source: .lms)
        let sameId = item("a", at(2026, 10, 24), source: .radar, kind: .opportunity)
        let r = Agenda.merge(old: [exam, post, stale, sameId], fresh: [item("a", at(2026, 10, 23))], source: .ics, now: NOW)
        #expect(Set(r.items.map(\.id)) == ["ledger:math201", "p1", "a"] && r.items.count == 4)  // the stale post is gone, "a" is there twice
        #expect(r.items.filter { $0.id == "a" }.map(\.source).sorted { $0.rawValue < $1.rawValue } == [.ics, .radar])
        #expect(r.changes.map(\.kind) == [.new])  // the radar's "a" is not the calendar's "a"
        #expect(r.items.contains(sameId) && r.items.contains(exam) && r.items.contains(post))
    }

    @Test func freshItemsOfAnotherSourceAreIgnoredAndOnesFromThePastAreNotAdded() {
        let r = Agenda.merge(old: [], fresh: [item("x", at(2026, 10, 25), source: .lms), item("gone", NOW.addingTimeInterval(-5 * 86_400)), item("ok", at(2026, 10, 25))],
                             source: .ics, now: NOW)
        #expect(r.items.map(\.id) == ["ok"] && r.changes.map(\.kind) == [.new])
    }

    @Test func twoFreshItemsWithOneIdAreOneItem() {
        let first = item("a", at(2026, 10, 25), title: "First"), second = item("a", at(2026, 10, 26), title: "Second")
        let r = Agenda.merge(old: [], fresh: [first, second], source: .ics, now: NOW)
        #expect(r.items == [first] && r.changes == [Agenda.Change(.new, first)])
    }

    @Test func itemsAreSortedByTimeThenIdAndSoAreTheChanges() {
        let fresh = [item("b", at(2026, 10, 24)), item("c", at(2026, 10, 22)), item("a", at(2026, 10, 24))]
        let r = Agenda.merge(old: [item("z", at(2026, 10, 23))], fresh: fresh, source: .ics, now: NOW)
        #expect(r.items.map(\.id) == ["c", "a", "b"])
        #expect(r.changes.map(\.item.id) == ["c", "z", "a", "b"])  // by the item's time: c 10-22, z 10-23 (removed), a and b 10-24
    }

    @Test func mergingTheSameFetchTwiceIsQuiet() {
        let fresh = [item("a", at(2026, 10, 25)), item("b", at(2026, 10, 22), kind: .exam)]
        let once = Agenda.merge(old: [], fresh: fresh, source: .ics, now: NOW)
        let twice = Agenda.merge(old: once.items, fresh: fresh, source: .ics, now: NOW.addingTimeInterval(600))
        #expect(twice.changes.isEmpty && twice.items == once.items)
    }

    @Test func aTeacherExtendingADeadlineInTheMoodleFeedIsOneMovedItem() throws {
        let first = Agenda.fromICS(ICS.parse(MOODLE, now: NOW, zone: VN).events, now: NOW)
        let stored = Agenda.merge(old: [], fresh: first, source: .ics, now: NOW).items
        let later = NOW.addingTimeInterval(3 * 3600)
        let second = Agenda.fromICS(ICS.parse(MOODLE_EXTENDED, now: later, zone: VN).events, now: later)
        let r = Agenda.merge(old: stored, fresh: second, source: .ics, now: later)
        let moved = try #require(r.changes.first)
        #expect(r.changes.count == 1 && moved.kind == .moved)
        #expect(moved.item.id == "48113@moodle.uni.example" && moved.was == at(2026, 10, 23, 16) && moved.item.when == at(2026, 10, 25, 16))
        #expect(moved.item.changed && moved.item.firstSeen == first[0].firstSeen)
    }

    // MARK: the file

    @Test func theFileRoundTripsAndIsStable() {
        let items = [
            AgendaItem(id: "48113@moodle.uni.example", title: "Assignment 2", course: "MATH201", kind: .deadline, when: at(2026, 10, 23, 16),
                       source: .ics, url: "https://moodle.uni.example/mod/assign/view.php?id=7731", quote: "due Friday", recurring: false,
                       firstSeen: LONG_AGO, changed: true),
            item("ledger:math201", at(2026, 10, 28, 2), source: .ledger, kind: .exam),
        ]
        let data = Agenda.encode(items)
        #expect(Agenda.decode(data) == items)
        #expect(Agenda.encode(items) == data && Agenda.encode(Agenda.decode(data)) == data)
    }

    @Test func theFileHasSortedKeysIsoDatesInUTCAndUnescapedLinks() throws {
        let one = AgendaItem(id: "x", title: "T", course: "C1", kind: .exam, when: at(2026, 10, 20, 2), source: .ledger, url: "https://a.example/b/c", quote: "q",
                             recurring: true, firstSeen: at(2026, 10, 1, 1, 2), changed: false)
        let text = String(decoding: Agenda.encode([one]), as: UTF8.self)
        #expect(text.contains("\"when\" : \"2026-10-20T02:00:00Z\"") && text.contains("\"firstSeen\" : \"2026-10-01T01:02:00Z\""))
        #expect(text.contains("https://a.example/b/c") && !text.contains("\\/"))
        let keys = ["changed", "course", "firstSeen", "id", "kind", "quote", "recurring", "source", "title", "url", "when"]
        let positions = try keys.map { try #require(text.range(of: "\"\($0)\"")).lowerBound }
        #expect(positions == positions.sorted())
        #expect(text.contains("\"kind\" : \"exam\"") && text.contains("\"source\" : \"ledger\""))
    }

    @Test func missingOptionalFieldsAreLeftOutAndComeBackNil() {
        let plain = item("a", at(2026, 10, 25))
        let text = String(decoding: Agenda.encode([plain]), as: UTF8.self)
        #expect(!text.contains("course") && !text.contains("url") && !text.contains("quote"))
        let back = Agenda.decode(Agenda.encode([plain]))
        #expect(back == [plain] && back[0].course == nil && back[0].url == nil && back[0].quote == nil)
    }

    @Test func anEmptyListRoundTrips() {
        #expect(Agenda.decode(Agenda.encode([])).isEmpty)
    }

    @Test(arguments: ["", "   ", "null", "{}", "[1, 2]", "not json", "{\"items\": []}", "[{\"id\": 5}]", "\u{0}\u{1}\u{2}", "[["])
    func aFileThatIsNotAListGivesNothing(_ text: String) {
        #expect(Agenda.decode(Data(text.utf8)).isEmpty)
    }

    @Test func oneBrokenItemCostsOnlyItself() {
        let good = #"{"id":"a","title":"A","kind":"deadline","when":"2026-10-25T00:00:00Z","source":"ics","recurring":false,"firstSeen":"2026-10-01T00:00:00Z","changed":false}"#
        let unknownKind = good.replacingOccurrences(of: "\"deadline\"", with: "\"party\"").replacingOccurrences(of: "\"a\"", with: "\"b\"")
        let noID = good.replacingOccurrences(of: "\"id\":\"a\",", with: "")
        let badDate = good.replacingOccurrences(of: "2026-10-25T00:00:00Z", with: "tomorrow").replacingOccurrences(of: "\"a\"", with: "\"c\"")
        let extra = good.replacingOccurrences(of: "\"id\":\"a\"", with: "\"id\":\"d\",\"future\":[1,2,3]")
        let items = Agenda.decode(Data("[\(good),\(unknownKind),\(noID),42,null,\(badDate),\(extra)]".utf8))
        #expect(items.map(\.id) == ["a", "d"])
        #expect(items[0].when == at(2026, 10, 25) && items[0].course == nil)
    }

    // MARK: from the calendar feed

    @Test func moodleEventsBecomeDeadlinesWithTheirCourseAndTheLinkFromTheDescription() throws {
        let items = Agenda.fromICS(ICS.parse(MOODLE, now: NOW, zone: VN).events, now: NOW)
        #expect(items.map(\.title) == ["Assignment 2: Eigenvalues is due", "Quiz 5: Orthogonality opens", "MATH201 midterm exam"])
        #expect(items.map(\.kind) == [.deadline, .event, .exam])
        #expect(items.allSatisfy { $0.source == .ics && !$0.recurring && !$0.changed && $0.course == "MATH201 Linear Algebra" && $0.quote == nil })
        #expect(items.map(\.id) == ["48113@moodle.uni.example", "48121@moodle.uni.example", "48155@moodle.uni.example"])
        #expect(items[0].url == "https://moodle.uni.example/mod/assign/view.php?id=7731")
        #expect(items[1].url == nil)
        #expect(items[0].when == at(2026, 10, 23, 16))
    }

    @Test func outlookClassesGetOneIdPerOccurrenceAndAllDayHolidaysAreLeftOut() {
        let events = ICS.parse(OUTLOOK, now: NOW, zone: VN).events
        let items = Agenda.fromICS(events, now: NOW)
        let lectures = items.filter { $0.title == "MATH201 Lecture" }
        #expect(lectures.count == 5)  // 12 Tuesdays from Sep 8: the ones on 10-20, 10-27, 11-03, 11-10 and 11-17 are in the window
        #expect(lectures.allSatisfy { $0.recurring && $0.kind == .event && $0.course == nil })  // "Blue category" is a colour, not a course
        #expect(Set(lectures.map(\.id)).count == 5)
        #expect(lectures[0].id == "040000008200E00074C5B7101A82E008000000001111@\(Int(at(2026, 10, 20, 10, 0, TimeZone(identifier: "Europe/Berlin")!).timeIntervalSince1970))")
        #expect(!items.contains { $0.title == "Reading week" })  // all-day and no deadline
        let outline = items.first { $0.title == "Thesis outline due" }
        #expect(outline?.kind == .deadline && outline?.when == at(2026, 10, 30, 0, 0, VN) && outline?.id == "040000008200E00074C5B7101A82E008000000003333")
    }

    @Test func aMeetingGetsTheLinkFromItsBodyWithoutTheFullStop() throws {
        let items = Agenda.fromICS(ICS.parse(OUTLOOK, now: NOW, zone: VN).events, now: NOW)
        let meeting = try #require(items.first { $0.title == "Project meeting" })
        #expect(meeting.kind == .event && !meeting.recurring)
        #expect(meeting.url == "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d")
    }

    /// The words that make a title a deadline or an exam; nil = no word of the lists.
    @Test(arguments: [
        ("Assignment 2: Eigenvalues is due", AgendaItem.Kind.deadline), ("Quiz 4: SVD closes", .deadline), ("Quiz 4", .deadline),
        ("Homework 3", .deadline), ("Coursework", .deadline), ("Project submission", .deadline), ("Please SUBMIT the form", .deadline),
        ("Registration deadline", .deadline), ("Deadlines this week", .deadline), ("Lab report 3 is DUE", .deadline),
        ("MATH201 midterm exam", .exam), ("Final exam", .exam), ("Midterms", .exam), ("exam", .exam),
        ("Exam registration deadline", .deadline), ("Exam 1 submission is due", .deadline), ("Quiz 5: Orthogonality opens", .event),
        ("Assignment 3 opens", .event), ("Exam hall opens", .event),
    ] as [(String, AgendaItem.Kind)])
    func aTitleIsClassifiedByItsWords(_ title: String, _ kind: AgendaItem.Kind) {
        #expect(Agenda.classify(title) == kind, "\(title)")
    }

    @Test(arguments: ["MATH201 Lecture", "Project meeting", "Office hours", "Lunch with Minh", "", "Introduction to Procedure", "Residue", "Duet", "Examination room tour",
                      "Open day", "Subdue"])
    func aTitleWithoutAWordOfTheListsIsNothing(_ title: String) {
        #expect(Agenda.classify(title) == nil, "\(title)")  // whole words only: "Procedure" has no "due"
    }

    @Test func theCategoriesDecideWhenTheTitleSaysNothing() {
        let plain = ICSEvent(uid: "u1", summary: "Week 7", start: at(2026, 10, 25), categories: "Quiz")
        let titled = ICSEvent(uid: "u2", summary: "Week 7 is due", start: at(2026, 10, 25), categories: "Midterm")
        let none = ICSEvent(uid: "u3", summary: "Week 7", start: at(2026, 10, 25), categories: "MATH201")
        #expect(Agenda.fromICS([plain, titled, none], now: NOW).map(\.kind) == [.deadline, .deadline, .event])
    }

    @Test func twoEventsWithOneIdAreOneItemAndAnEmptyTitleIsLabelled() {
        let a = ICSEvent(uid: "dup", summary: "First", start: at(2026, 10, 25)), b = ICSEvent(uid: "dup", summary: "Second", start: at(2026, 10, 26))
        let blank = ICSEvent(uid: "blank", summary: "   ", start: at(2026, 10, 27))
        let items = Agenda.fromICS([a, b, blank], now: NOW)
        #expect(items.map(\.title) == ["First", "(untitled)"])
    }

    @Test func firstSeenIsNowInWholeSeconds() {
        let e = ICSEvent(uid: "u", summary: "Thing", start: at(2026, 10, 25))
        #expect(Agenda.fromICS([e], now: NOW.addingTimeInterval(0.789))[0].firstSeen == NOW)
    }

    @Test(arguments: [
        ("see https://a.example/x.", "https://a.example/x"), ("(https://a.example/x)", "https://a.example/x"), ("<a href=\"https://a.example/x\">", "https://a.example/x"),
        ("https://a.example/x?y=1&z=2, then", "https://a.example/x?y=1&z=2"), ("first https://one.example then https://two.example", "https://one.example"),
    ])
    func theFirstHttpsLinkIsFoundWithoutTheSentencePunctuation(_ text: String, _ want: String) {
        #expect(Agenda.link(in: text) == want)
    }

    @Test(arguments: ["", "no link", "http://insecure.example/x", "ftp://x.example/y", "javascript:alert(1)", "https://", "https://a", "mailto:x@y.example"])
    func onlyAnHttpsLinkIsTaken(_ text: String) {
        #expect(Agenda.link(in: text) == nil, "\(text)")
    }

    // MARK: from the study ledger

    @Test func theLedgersExamBecomesAnExamItem() throws {
        let items = Agenda.ledgerExams(from: LEDGER, zone: VN, now: NOW)
        let exam = try #require(items.first)
        #expect(items.count == 1)
        #expect(exam == AgendaItem(id: "ledger:math201-linear-algebra-midterm", title: "MATH201 Linear Algebra midterm", course: "MATH201", kind: .exam,
                                   when: at(2026, 10, 20, 2), source: .ledger, url: nil, quote: nil, recurring: false, firstSeen: NOW, changed: false))
    }

    @Test func theExamTimeIsInTheGivenZoneAndTopicsGoToTheQuote() throws {
        let ledger = "## Exams\n- 2026-10-11 · MATH201 Linear Algebra midterm · 2026-10-20 09:00 · topics: eigenvalues; SVD\n"
        #expect(try #require(Agenda.ledgerExams(from: ledger, zone: VN, now: NOW).first).when == at(2026, 10, 20, 2))
        #expect(try #require(Agenda.ledgerExams(from: ledger, zone: NEW_YORK, now: NOW).first).when == at(2026, 10, 20, 9, 0, NEW_YORK))
        #expect(try #require(Agenda.ledgerExams(from: ledger, zone: VN, now: NOW).first).quote == "topics: eigenvalues; SVD")
    }

    @Test(arguments: [
        ("- 2026-10-11 · CS301 Software Engineering final · 2026-12-15", at(2026, 12, 15, 9, 0, VN)),  // no time: 09:00
        ("- 2026-10-11 · CS301 final · 2026-12-15 14:30", at(2026, 12, 15, 14, 30, VN)),
        ("- 2026-10-11 · CS301 final · 2026-12-15 9:05", at(2026, 12, 15, 9, 5, VN)),
        ("- 2026-10-11 · CS301 final · 2026-12-15 00:00", at(2026, 12, 15, 0, 0, VN)),
        ("- 2026-10-11 · CS301 final · 2026-12-15 23:59", at(2026, 12, 15, 23, 59, VN)),
        ("- 2026-10-11 · CS301 final · 2026-12-15 14:30 (Hall B)", at(2026, 12, 15, 14, 30, VN)),
        ("-   2026-10-11   ·   CS301 final   ·   2026-12-15 14:30   ", at(2026, 12, 15, 14, 30, VN)),
        ("- 2026-10-11 · CS301 final · 2026-12-15 14:30 · room: A1 · topics: graphs", at(2026, 12, 15, 14, 30, VN)),
        ("-2026-10-11 · CS301 final · 2026-12-15 14:30", at(2026, 12, 15, 14, 30, VN)),
        ("- 2024-02-29 · CS301 final · 2028-02-29 08:00", at(2028, 2, 29, 8, 0, VN)),
    ] as [(String, Date)])
    func examLinesInTheFormsTheSkillWritesAreRead(_ line: String, _ when: Date) throws {
        let item = try #require(Agenda.ledgerExams(from: "## Exams\n" + line + "\n", zone: VN, now: NOW).first)
        #expect(item.when == when && item.kind == .exam && item.source == .ledger)
    }

    @Test(arguments: [
        "- 2026-10-11 · MATH201 midterm", "- 2026-10-11", "-", "- ·  · ", "- · MATH201 midterm · 2026-10-20 09:00", "- 2026-13-11 · X · 2026-10-20",
        "- 2026-10-11 · X · 2026-02-30", "- 2026-10-11 · X · 2026-10-20 25:00", "- 2026-10-11 · X · 2026-10-20 09:60", "- 2026-10-11 · X · 2026-10-20 9",
        "- 2026-10-11 · X · 2026-10-20 09:00pm", "- 2026-10-11 ·  · 2026-10-20 09:00", "- 2026-10-11 · X · tomorrow", "- 2026-10-11 · X · 20-10-2026",
        "- 2026-10-11 · X · 2026/10/20", "- 2026-10-11 · X · 2026-10-20T09:00", "* 2026-10-11 · X · 2026-10-20", "2026-10-11 · X · 2026-10-20",
        "- 2026-10-11 · X · ", "- yesterday · X · 2026-10-20", "- 2026-10-11 · X · 1969-12-31", "- 2026-10-11 · X · 2026-00-10", "Exam on 2026-10-20",
        "- 2026-02-30 · X · 2026-10-20", "",
    ])
    func aMalformedExamLineIsSkippedAndTheNextOneStillCounts(_ bad: String) {
        let ledger = "## Exams\n" + bad + "\n- 2026-10-11 · GOOD101 Good one · 2026-10-21 10:00\n"
        #expect(Agenda.ledgerExams(from: ledger, zone: VN, now: NOW).map(\.title) == ["GOOD101 Good one"], "\(bad)")
    }

    @Test func onlyTheExamsSectionCounts() {
        let line = "- 2026-10-11 · MATH201 Linear Algebra midterm · 2026-10-20 09:00"
        for text in ["## Goals\n" + line + "\n", "## Results\n" + line + "\n", "## Exams and quizzes\n" + line + "\n", "### Exams\n" + line + "\n",
                     "## Examples\n" + line + "\n", line + "\n", "# Exams\n" + line + "\n", "## Exams\n## Results\n" + line + "\n", "## Notes\n" + line + "\n## Exams\n"] {
            #expect(Agenda.ledgerExams(from: text, zone: VN, now: NOW).isEmpty, "\(text.debugDescription)")
        }
        #expect(Agenda.ledgerExams(from: "## exams  \n" + line + "\n", zone: VN, now: NOW).count == 1)
        #expect(Agenda.ledgerExams(from: "## Goals\n- x\n\n## Exams\n" + line + "\n\n## Results\n- 2026-10-11 · MATH201 quiz · 2026-10-25\n", zone: VN, now: NOW).count == 1)
    }

    @Test func windowsLineEndingsAndAMissingFinalNewlineAreFine() {
        let text = "# Study ledger\r\n\r\n## Exams\r\n- 2026-10-11 · MATH201 Linear Algebra midterm · 2026-10-20 09:00\r\n- 2026-10-12 · CS301 final · 2026-12-15 14:00"
        #expect(Agenda.ledgerExams(from: text, zone: VN, now: NOW).map(\.title) == ["MATH201 Linear Algebra midterm", "CS301 final"])
    }

    @Test func examsAreSortedByTime() {
        let text = "## Exams\n- 2026-10-11 · B final · 2026-12-15 14:00\n- 2026-10-11 · A midterm · 2026-10-20 09:00\n- 2026-10-11 · C quiz · 2026-11-02\n"
        #expect(Agenda.ledgerExams(from: text, zone: VN, now: NOW).map(\.title) == ["A midterm", "C quiz", "B final"])
    }

    @Test func aSubjectWithoutACourseCodeHasNoCourse() {
        let text = "## Exams\n- 2026-10-11 · Linear Algebra midterm · 2026-10-20\n- 2026-10-11 · Math201 midterm · 2026-10-21\n- 2026-10-11 · MATH201B midterm · 2026-10-22\n- 2026-10-11 · A1 midterm · 2026-10-23\n"
        #expect(Agenda.ledgerExams(from: text, zone: VN, now: NOW).map(\.course) == [nil, nil, "MATH201B", nil])
    }

    @Test func aMovedExamKeepsItsIdSoMergeCallsItMovedAndTheSameSubjectTwiceKeepsTheLaterLine() throws {
        let before = "## Exams\n- 2026-10-11 · MATH201 Linear Algebra midterm · 2026-10-20 09:00\n"
        let after = "## Exams\n- 2026-10-11 · MATH201  Linear Algebra Midterm · 2026-10-27 09:00\n"  // the skill patched the date; case and spacing differ
        let stored = Agenda.merge(old: [], fresh: Agenda.ledgerExams(from: before, zone: VN, now: NOW), source: .ledger, now: NOW).items
        let r = Agenda.merge(old: stored, fresh: Agenda.ledgerExams(from: after, zone: VN, now: NOW), source: .ledger, now: NOW)
        #expect(r.changes.map(\.kind) == [.moved] && r.changes[0].was == at(2026, 10, 20, 2))

        let twice = "## Exams\n- 2026-10-05 · MATH201 midterm · 2026-10-20 09:00\n- 2026-10-12 · MATH201 midterm · 2026-10-27 09:00\n"
        let reversed = "## Exams\n- 2026-10-12 · MATH201 midterm · 2026-10-27 09:00\n- 2026-10-05 · MATH201 midterm · 2026-10-20 09:00\n"
        for text in [twice, reversed] {
            let items = Agenda.ledgerExams(from: text, zone: VN, now: NOW)
            #expect(try #require(items.first).when == at(2026, 10, 27, 2) && items.count == 1)
        }
    }

    @Test func theLedgerLinesOfOtherLanguagesAndSymbolsKeepTheirTitle() throws {
        let text = "## Exams\n- 2026-10-11 · MATH201 Đại số tuyến tính giữa kỳ (đề 1) · 2026-10-20 09:00\n"
        let item = try #require(Agenda.ledgerExams(from: text, zone: VN, now: NOW).first)
        #expect(item.title == "MATH201 Đại số tuyến tính giữa kỳ (đề 1)" && item.id == "ledger:math201-đại-số-tuyến-tính-giữa-kỳ-đề-1" && item.course == "MATH201")
    }
}
