// The LMS posts' strict half: which replies are accepted (one fenced block that is a list), which course and post addresses may pass,
// which objects become agenda items (every check, one by one), how text is cleaned, and which step of the day comes next.
import Foundation
import Testing
@testable import RoboCore

private let VN = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
private let HOST = "moodle.example.edu"

private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ zone: TimeZone = VN) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

/// Tuesday 2026-10-20, 09:00 in Vietnam.
private let NOW = at(2026, 10, 20, 9, 0)

private func reply(_ list: [[String: Any]], before: String = "Read 31 posts.") -> String {
    let data = try! JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])
    return before + "\n\n```json\n" + String(decoding: data, as: UTF8.self) + "\n```"
}

private func scan(_ list: [[String: Any]]) -> Result<LMSPosts.Parsed<AgendaItem>, LMSPosts.Failure> {
    LMSPosts.items(in: reply(list), host: HOST, today: NOW, zone: VN, now: NOW)
}

/// The skill's own example, then whatever `change` sets (a nil value is JSON null).
private func post(_ change: [String: String?] = [:]) -> [String: Any] {
    var o: [String: Any] = [
        "course": "MATH201", "post_url": "https://\(HOST)/mod/forum/discuss.php?d=5521", "posted": "2026-10-19",
        "title": "Problem set 4 moved", "due": "2026-10-23T23:59", "kind": "deadline",
        "quote": "Problem set 4 is now due Friday 23 October at 23:59.",
    ]
    for (key, value) in change { o[key] = value ?? NSNull() }
    return o
}

private func course(_ name: String, _ url: String) -> [String: Any] { ["name": name, "url": url] }

private extension Result {
    var failureOrNil: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

@Suite struct LMSReplyTests {
    @Test func oneFencedListIsTheOnlyReplyThatCounts() throws {
        #expect(try LMSPosts.list(in: reply([post()])).get().count == 1)
        #expect(try LMSPosts.list(in: "```json\n[]\n```").get().isEmpty)  // no sentence is fine
        #expect(try LMSPosts.list(in: "```JSON\n[]\n```").get().isEmpty)
        for text in ["I could not read the page.", "```python\n[]\n```", reply([post()]) + "\n```json\n[]\n```", "```json\n[]\n"] {
            #expect(LMSPosts.list(in: text).failureOrNil == .noBlock, "\(text)")
        }
        for text in ["```json\n{\"a\": 1}\n```", "```json\nnot json\n```", "```json\n\"[]\"\n```", "```json\n```"] {
            #expect(LMSPosts.list(in: text).failureOrNil == .notAList, "\(text)")
        }
    }

    @Test func aFailedReplyIsAFailureForBothKinds() {
        #expect(LMSPosts.courses(in: "no block", host: HOST).failureOrNil == .noBlock)
        #expect(LMSPosts.items(in: "no block", host: HOST, today: NOW, zone: VN, now: NOW).failureOrNil == .noBlock)
    }
}

@Suite struct LMSCoursesTests {
    private func parse(_ list: [[String: Any]]) throws -> LMSPosts.Parsed<LMSPosts.Course> {
        try LMSPosts.courses(in: reply(list), host: HOST).get()
    }

    @Test func courseListIsReadAndTheHostIsMatchedWithoutCase() throws {
        let got = try parse([course("Linear Algebra (MATH201)", "https://\(HOST)/course/view.php?id=1234"),
                             course("Physics lab", "https://MOODLE.Example.edu/course/view.php?id=1301")])
        #expect(got.values == [.init(name: "Linear Algebra (MATH201)", url: "https://\(HOST)/course/view.php?id=1234"),
                               .init(name: "Physics lab", url: "https://\(HOST)/course/view.php?id=1301")])
        #expect(got.dropped == 0)
    }

    @Test(arguments: [
        "https://other.example.edu/course/view.php?id=1",  // another host
        "https://moodle.example.edu.evil.com/course/view.php?id=1",  // a host that only starts like it
        "http://moodle.example.edu/course/view.php?id=1",  // not https
        "https://user:pw@moodle.example.edu/course/view.php?id=1",
        "https://moodle.example.edu:8443/course/view.php?id=1",
        "https://moodle.example.edu/mod/quiz/attempt.php?attempt=1",  // graded work: never a place to send the agent
        "https://moodle.example.edu/mod/assign/view.php?id=1",
        "https://moodle.example.edu/course/view.php?id=1&section=2",  // anything beyond the id
        "https://moodle.example.edu/course/view.php?id=",
        "https://moodle.example.edu/course/view.php?id=12a",
        "https://moodle.example.edu/course/view.php",
        "https://moodle.example.edu/course/view.php?id=1#x",
        "https://moodle.example.edu/course/view.php?id=1 2",
    ])
    func onlyACoursePageOfTheHostPasses(url: String) throws {
        let got = try parse([course("A course", url)])
        #expect(got.values.isEmpty && got.dropped == 1, "\(url)")
    }

    @Test func aBadNameADuplicateAndTooManyAreDropped() throws {
        let url = { (n: Int) in "https://\(HOST)/course/view.php?id=\(n)" }
        let got = try parse([course("One", url(1)), course("One again", url(1)), ["name": " \n ", "url": url(2)], ["name": "No url"], ["url": url(3)]])
        #expect(got.values.map(\.name) == ["One"] && got.dropped == 4)
        let many = try parse((1...55).map { course("C\($0)", url($0)) })
        #expect(many.values.count == LMSPosts.maxCourses && many.dropped == 15)
    }
}

@Suite struct LMSItemsTests {
    @Test func theSkillsOwnExampleBecomesAnAgendaItem() throws {
        let got = try scan([post()]).get()
        #expect(got.dropped == 0)
        let item = try #require(got.values.first)
        #expect(item.id == "lms:math201:problem-set-4-moved" && item.title == "Problem set 4 moved" && item.course == "MATH201")
        #expect(item.kind == .deadline && item.source == .lms && item.when == at(2026, 10, 23, 23, 59))
        #expect(item.url == "https://\(HOST)/mod/forum/discuss.php?d=5521" && item.quote == "Problem set 4 is now due Friday 23 October at 23:59.")
        #expect(!item.recurring && !item.changed && item.firstSeen == NOW)
    }

    @Test func aDayWithoutATimeIsTheEndOfThatDay() throws {
        let item = try #require(scan([post(["due": "2026-10-23"])]).get().values.first)
        #expect(item.when == at(2026, 10, 23, 23, 59))
    }

    @Test func aPostOfTodayDueThisAfternoonIsKept() throws {
        let item = try #require(scan([post(["posted": "2026-10-20", "due": "2026-10-20T17:00"])]).get().values.first)
        #expect(item.when == at(2026, 10, 20, 17, 0))
        // the post of the 19th that says "due today 10:00" is also a deadline on its own day
        #expect(try scan([post(["posted": "2026-10-19", "due": "2026-10-19T10:00"])]).get().values.count == 1)
    }

    @Test func eachKindThatMakesAReminderIsKept() throws {
        let kinds = try scan(["deadline", "exam", "event"].map { post(["kind": $0, "title": "T \($0)"]) }).get().values
        #expect(Set(kinds.map(\.kind)) == [.deadline, .exam, .event])
    }

    @Test(arguments: [
        ("due", nil as String?),  // no date: nothing to remind at
        ("due", "2026-02-30T10:00"),  // a day that does not exist
        ("due", "2026-10-23T25:00"),
        ("due", "next Friday"),
        ("due", "2026-10-23 10:00"),
        ("due", "2026-10-18T10:00"),  // before the post that states it
        ("due", "2029-10-23T10:00"),  // more than two years after it
        ("posted", "2026-10-21"),  // after today: a misreading
        ("posted", "2024-01-01"),  // implausibly old
        ("posted", "2026-10-19T10:00"),  // a day, not a moment
        ("posted", nil),
        ("kind", "reading"),
        ("kind", "quiz"),
        ("kind", nil),
        ("post_url", "https://\(HOST)/mod/quiz/attempt.php?attempt=9"),  // Open would put graded work in the browser
        ("post_url", "https://\(HOST)/mod/assign/view.php?id=9"),
        ("post_url", "https://other.example.edu/mod/forum/discuss.php?d=1"),
        ("post_url", "https://\(HOST).evil.com/mod/forum/discuss.php?d=1"),
        ("post_url", "http://\(HOST)/mod/forum/discuss.php?d=1"),
        ("post_url", "https://user:pw@\(HOST)/mod/forum/discuss.php?d=1"),
        ("post_url", "javascript:alert(1)"),
        ("post_url", nil),
        ("quote", ""),  // nothing to check the date against
        ("quote", nil),
        ("title", " \n\t "),
        ("course", nil),
    ])
    func anObjectThatFailsOneCheckIsDroppedAndCounted(field: String, value: String?) throws {
        #expect(try scan([post()]).get().values.count == 1)  // the control: all the others pass
        let got = try scan([post([field: value])]).get()
        #expect(got.values.isEmpty && got.dropped == 1, "\(field) = \(value ?? "null")")
    }

    @Test func textIsOneCleanLineAndCut() throws {
        let item = try #require(scan([post(["title": "Quiz\u{202E} 4\n\tmoved\u{0}", "course": String(repeating: "C", count: 200),
                                            "quote": String(repeating: "q ", count: 200)])]).get().values.first)
        #expect(item.title == "Quiz 4 moved")  // the right-to-left override, the newline and the NUL are gone
        #expect(item.course?.count == 80 && (item.quote?.count ?? 0) <= 120 && !(item.quote ?? "").contains("\n"))
        #expect(LMSPosts.line(42, max: 10) == nil && LMSPosts.line("  ", max: 10) == nil && LMSPosts.line("a  b", max: 10) == "a b")
    }

    @Test func twoPostsOnOneThingKeepTheLaterOne() throws {
        let older = post(["posted": "2026-10-13", "due": "2026-10-22T23:59", "title": "Lab report 2", "post_url": "https://\(HOST)/mod/forum/discuss.php?d=1"])
        let newer = post(["posted": "2026-10-19", "due": "2026-10-26T23:59", "title": "lab report 2!", "post_url": "https://\(HOST)/mod/forum/discuss.php?d=2"])
        for order in [[older, newer], [newer, older]] {
            let got = try scan(order).get()
            #expect(got.values.count == 1 && got.dropped == 1)
            #expect(got.values.first?.when == at(2026, 10, 26, 23, 59) && got.values.first?.url?.hasSuffix("d=2") == true)
        }
    }

    @Test func itemsAreSortedByTimeAndCappedAtSixty() throws {
        let sorted = try scan([post(["title": "b", "due": "2026-10-25"]), post(["title": "a", "due": "2026-10-24"])]).get().values
        #expect(sorted.map(\.title) == ["a", "b"])
        let many = try scan((1...70).map { post(["title": "Item \($0)"]) }).get()
        #expect(many.values.count == LMSPosts.maxItems && many.dropped == 10)
    }

    @Test func entriesThatAreNotObjectsAreDroppedOneByOne() throws {
        let text = "```json\n[1, \"x\", null, [], {\"course\": 3}]\n```"
        let got = try LMSPosts.items(in: text, host: HOST, today: NOW, zone: VN, now: NOW).get()
        #expect(got.values.isEmpty && got.dropped == 5)
    }

    @Test func theDaysUseTheUsersZoneNotUTC() throws {
        // 2026-10-20 23:30 in New York is already the 21st in UTC; a post of the 20th is today's, one of the 21st is tomorrow's.
        let york = TimeZone(identifier: "America/New_York")!
        let late = at(2026, 10, 20, 23, 30, york)
        func run(_ posted: String) throws -> Int {
            try LMSPosts.items(in: reply([post(["posted": posted, "due": "2026-10-25"])]), host: HOST, today: late, zone: york, now: late).get().values.count
        }
        #expect(try run("2026-10-20") == 1)
        #expect(try run("2026-10-21") == 0)
    }
}

@Suite struct LMSPlanTests {
    private let a = LMSPosts.Course(name: "A", url: "https://\(HOST)/course/view.php?id=1")
    private let b = LMSPosts.Course(name: "B", url: "https://\(HOST)/course/view.php?id=2")

    @Test func theListComesFirstWhenThereIsNoneOrItIsAWeekOld() {
        #expect(LMSPosts.next(courses: [], coursesDay: "", scanned: [:], today: "2026-10-20") == .list)
        #expect(LMSPosts.next(courses: [a], coursesDay: "2026-10-13", scanned: [:], today: "2026-10-20") == .list)  // 7 days
        #expect(LMSPosts.next(courses: [a], coursesDay: "2026-10-14", scanned: [:], today: "2026-10-20") != .list)  // 6 days
        #expect(LMSPosts.next(courses: [a], coursesDay: "not a day", scanned: [:], today: "2026-10-20") == .list)
        // a list that came back empty today is not read again today (every 30 s tick would ask the agent again); tomorrow it is
        #expect(LMSPosts.next(courses: [], coursesDay: "2026-10-20", scanned: [:], today: "2026-10-20") == nil)
        #expect(LMSPosts.next(courses: [], coursesDay: "2026-10-19", scanned: [:], today: "2026-10-20") == .list)
        #expect(LMSPosts.next(courses: [], coursesDay: "", scanned: [:], today: "2026-10-20", skip: ["list"]) == nil)  // failed too often
    }

    @Test func eachCourseIsScannedOnceADayFromItsLastGoodScan() {
        let today = "2026-10-20", fresh = "2026-10-19"
        // a course never scanned reads back the first lookback (yesterday), no further
        #expect(LMSPosts.next(courses: [a, b], coursesDay: today, scanned: [:], today: today) == .scan(a, since: fresh))
        #expect(LMSPosts.next(courses: [a, b], coursesDay: today, scanned: [a.url: today], today: today) == .scan(b, since: fresh))
        #expect(LMSPosts.next(courses: [a, b], coursesDay: today, scanned: [a.url: today, b.url: today], today: today) == nil)
        // after a gap it reads back to the last good scan
        #expect(LMSPosts.next(courses: [a], coursesDay: today, scanned: [a.url: "2026-10-12"], today: today) == .scan(a, since: "2026-10-12"))
        // a last scan "in the future" (a clock set back) or garbage reads from yesterday
        #expect(LMSPosts.next(courses: [a], coursesDay: today, scanned: [a.url: "2026-11-01"], today: today) == .scan(a, since: fresh))
        #expect(LMSPosts.next(courses: [a], coursesDay: today, scanned: [a.url: "soon"], today: today) == .scan(a, since: fresh))
    }

    @Test func aStepThatFailedTooOftenIsSkippedAndTheNextOneGoes() {
        let today = "2026-10-20"
        #expect(LMSPosts.next(courses: [a, b], coursesDay: today, scanned: [:], today: today, skip: [a.url]) == .scan(b, since: "2026-10-19"))
        #expect(LMSPosts.next(courses: [a, b], coursesDay: today, scanned: [:], today: today, skip: [a.url, b.url]) == nil)
        #expect(LMSPosts.next(courses: [a], coursesDay: today, scanned: [:], today: "garbage") == nil)
    }

    @Test func thePromptsNameTheModeTheCourseAndTheDays() {
        #expect(LMSPosts.listPrompt.hasPrefix("MODE: list\n"))
        let text = LMSPosts.scanPrompt(a, since: "2026-10-19", today: "2026-10-20")
        #expect(text == "MODE: scan\nCOURSE: \(a.url)\nSINCE: 2026-10-19\nTODAY: 2026-10-20\nUse the school-posts skill.")
        #expect(LMSPosts.Step.list.key == "list" && LMSPosts.Step.scan(a, since: "x").key == a.url)
    }
}

private let PAGE = "https://\(HOST)/course/view.php?id=1234"

/// The skill's own example of a material, then whatever `change` sets (a nil value is JSON null).
private func material(_ change: [String: String?] = [:]) -> [String: Any] {
    var o: [String: Any] = ["course": "MATH201", "post_url": PAGE, "posted": "2026-10-20", "title": "Lecture 5 slides", "due": NSNull(),
                            "kind": "material", "quote": "Updated File: Lecture 5 slides"]
    for (key, value) in change { o[key] = value ?? NSNull() }
    return o
}

private func materials(_ list: [[String: Any]]) -> Result<LMSPosts.Parsed<LMSPosts.Material>, LMSPosts.Failure> {
    LMSPosts.materials(in: reply(list), host: HOST, page: PAGE, today: NOW, zone: VN, now: NOW)
}

@Suite struct LMSMaterialsTests {
    @Test func theSkillsOwnExampleIsAMaterialAndNeverAnAgendaItem() throws {
        let list = [post(), material()]
        let got = try materials(list).get()
        #expect(got.dropped == 0)
        #expect(got.values == [.init(id: "lms-material:math201:lecture-5-slides", course: "MATH201", title: "Lecture 5 slides", url: PAGE,
                                     posted: "2026-10-20", quote: "Updated File: Lecture 5 slides", firstSeen: NOW)])
        let items = try scan(list).get()  // the deadline stays an item, and the material is not counted as a dropped one
        #expect(items.values.map(\.title) == ["Problem set 4 moved"] && items.dropped == 0)
        let none = try materials([post()]).get()  // a reply of dated items only has no materials
        #expect(none.values.isEmpty && none.dropped == 0)
    }

    @Test func theAddressIsThePostsWhenItPassesElseTheCoursePage() throws {
        let forum = "https://\(HOST)/mod/forum/discuss.php?d=5521"
        #expect(try materials([material(["post_url": forum])]).get().values.first?.url == forum)
        for bad in [nil, "https://other.example.edu/course/view.php?id=1", "https://\(HOST)/mod/quiz/attempt.php?attempt=1",
                    "https://\(HOST)/mod/resource/view.php?id=9", "http://\(HOST)/course/view.php?id=1", "not a link"] as [String?] {
            #expect(try materials([material(["post_url": bad])]).get().values.first?.url == PAGE, "\(bad ?? "nil")")  // never the file's own page
        }
    }

    @Test(arguments: [
        ("due", "2026-10-23"),  // a material has no due date: a dated thing is a deadline
        ("due", "2026-10-23T10:00"),
        ("posted", "2026-10-21"),  // tomorrow
        ("posted", "2026-10-20T10:00"),  // a day, not a moment
        ("posted", "yesterday"),
        ("posted", nil as String?),
        ("quote", ""), ("title", " \n "), ("course", ""),
    ])
    func aMaterialThatBreaksARuleIsDropped(field: String, value: String?) throws {
        let got = try materials([material([field: value])]).get()
        #expect(got.values.isEmpty && got.dropped == 1, "\(field)=\(value ?? "nil")")
    }

    @Test func aMissingDueIsFineAndTheSameMaterialTwiceIsOneWithTheLaterDay() throws {
        var bare = material()
        bare.removeValue(forKey: "due")
        #expect(try materials([bare]).get().values.count == 1)
        let got = try materials([material(["posted": "2026-10-18", "quote": "Added File: Lecture 5 slides"]), material(["posted": "2026-10-20"])]).get()
        #expect(got.values.count == 1 && got.values[0].posted == "2026-10-20" && got.dropped == 1)
        let other = try materials([material(["posted": "2026-10-20", "title": "A"]), material(["posted": "2026-10-19", "title": "B"])]).get()
        #expect(other.values.map(\.title) == ["A", "B"])  // newest first
    }

    @Test func textIsCleanedLikeEverywhereElse() throws {
        let got = try materials([material(["title": "Lecture\u{202E} 5\n slides", "quote": String(repeating: "x", count: 300)])]).get()
        #expect(got.values.first?.title == "Lecture 5 slides" && got.values.first?.quote.count == 120)
    }
}

@Suite struct LMSIncompleteTests {
    private func said(_ before: String, _ list: [[String: Any]] = []) -> String { reply(list, before: before) }

    @Test(arguments: [
        // the three real replies that were taken for "nothing new" or a whole list (2026-10-20 to 22)
        "Announcements has no post since 28 Sept, and the recent-activity page showed no new forum posts. I couldn't load the recent-activity view back to 21 Oct because that request was blocked, so I didn't retry it. I read 0 posts.",
        "I couldn't finish this scan. My click to open the Announcements forum was denied, so I stopped without trying another route.",
        "Only one course URL was confirmed, because my click to open the next course was denied and I stopped there.",
        "INCOMPLETE: the recent-activity page was refused, so I did not read it.",
        "I couldn\u{2019}t open the course.",  // a typographic apostrophe
        "I am unable to open the Announcements forum.", "The page would not load; I cannot tell if there is anything new.",
    ])
    func anAgentThatSaysItCouldNotReadEverythingHasNotScanned(sentence: String) {
        #expect(LMSPosts.incomplete(said(sentence)), "\(sentence)")
        #expect(LMSPosts.incomplete(sentence), "\(sentence)")  // and without any block
        #expect(LMSPosts.incomplete("```json\n[]\n```\n" + sentence))  // the words after the block count too
    }

    @Test(arguments: [
        "Read 31 posts.",
        "Read 2 announcement posts (Sep 28 and Aug 21), both before 2026-10-19, so nothing qualifies.",
        "Read the Announcements forum (2 discussions, newest 28 Sep) and the recent-activity page: no posts on or after 2026-10-19.",
        "Announcements has no post since 28 Sept, and the recent-activity page showed no new forum posts. I read 0 posts.",
        "Found 8 courses.", "Stopped at the 12 tool-call limit after 40 posts.", "",
    ])
    func aPlainAnswerIsNotIncomplete(sentence: String) {
        #expect(!LMSPosts.incomplete(said(sentence)), "\(sentence)")
    }

    @Test func wordsInsideTheBlockAreThePostsAndNeverCount() {
        let quoted = post(["quote": "Access denied is not an excuse; the form was blocked; I cannot extend it"])
        #expect(!LMSPosts.incomplete(said("Read 3 posts.", [quoted])))
        #expect(LMSPosts.incomplete(said("Read 3 posts, one page was blocked.", [quoted])))
    }
}
