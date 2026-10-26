// The LMS posts scan, end to end in the window: a fake Hermes answers each run with the reply a test gives it, the wall clock is a fake
// (UTC, so 07:00 is exact), and the files are temp folders (no test touches the real data folder or the real Hermes profile).
// `LMSPostsTests` (RoboCore) pins what a reply may hold; this pins when a run starts, what a run may do, and what becomes of its answer.
// 2026-10-20 is a Tuesday.
import AppKit
import Foundation
import Testing
import RoboCore
import RoboSystem
@testable import RoboUI

private let utc = TimeZone(identifier: "UTC")!
private let host = "moodle.example.edu"
private let courseA = LMSPosts.Course(name: "Linear Algebra (MATH201)", url: "https://\(host)/course/view.php?id=1")
private let courseB = LMSPosts.Course(name: "Physics lab (PHYS101)", url: "https://\(host)/course/view.php?id=2")

/// Seconds since 1970 of 2026-10-`day` at h:m UTC.
private func at(_ h: Int, _ m: Int = 0, day: Int = 20) -> Double {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = utc
    return cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!.timeIntervalSince1970
}

private func fenced(_ list: [[String: Any]]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])
    return "Done.\n\n```json\n" + String(decoding: data, as: UTF8.self) + "\n```"
}

private func courses(_ list: [LMSPosts.Course]) -> String { fenced(list.map { ["name": $0.name, "url": $0.url] }) }

/// A reply with the agent's own sentence in front of the block.
private func said(_ before: String, _ list: [[String: Any]] = []) -> String {
    let data = try! JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])
    return before + "\n\n```json\n" + String(decoding: data, as: UTF8.self) + "\n```"
}

/// One new learning material of MATH201 (the skill's example); `change` overrides fields.
private func material(_ change: [String: String] = [:]) -> [String: Any] {
    var o: [String: Any] = [
        "course": "MATH201", "post_url": courseA.url, "posted": "2026-10-20", "title": "Lecture 5 slides", "due": NSNull(),
        "kind": "material", "quote": "Updated File: Lecture 5 slides",
    ]
    for (key, value) in change { o[key] = value }
    return o
}

/// One post that states a deadline; `change` overrides fields.
private func post(_ change: [String: String] = [:]) -> [String: Any] {
    var o: [String: Any] = [
        "course": "MATH201", "post_url": "https://\(host)/mod/forum/discuss.php?d=5521", "posted": "2026-10-19",
        "title": "Problem set 4 moved", "due": "2026-10-23T23:59", "kind": "deadline",
        "quote": "Problem set 4 is now due Friday 23 October at 23:59.",
    ]
    for (key, value) in change { o[key] = value }
    return o
}

private func completed(_ text: String) -> [FakeHermes.Step] { [.event(.runEnded(status: "completed", output: text, error: ""))] }

/// Each run of the fake Hermes gets the next reply of the list (the last one again when it runs out).
private final class Replies: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [String]
    init(_ queue: [String]) { self.queue = queue }
    func next() -> String { lock.withLock { queue.count > 1 ? queue.removeFirst() : queue.first ?? "" } }
}

@MainActor private func serve(_ r: Rig, _ replies: [String]) {
    let queue = Replies(replies)
    r.hermes.onAsk = { [hermes = r.hermes] in hermes.script = completed(queue.next()) }
}

@MainActor private func launch(wall: Double = at(8), moodle: String? = "https://\(host)") async -> Rig {
    let r = Rig()
    r.moodle = moodle
    r.fake.wall = wall
    #expect(await pump(r.window.scout.started))
    return r
}

/// What the tick that runs every 30 s would do at wall time `wall`.
@MainActor private func tick(_ r: Rig, _ wall: Double) {
    r.fake.wall = wall
    r.window.nudgeTick()
}

/// The run that was started has come back and been dealt with.
@MainActor private func settled(_ r: Rig) async -> Bool { await pump(r.window.scout.running == nil) }

@MainActor private func state(_ r: Rig) -> LMSState { r.window.scout.state }
@MainActor private func asked(_ r: Rig) -> [String] { r.hermes.asked.map(\.text) }
@MainActor private func lmsItems(_ r: Rig) -> [AgendaItem] { r.window.nudge.agenda.filter { $0.source == .lms } }

@MainActor @Suite(.serialized) struct ScoutWindowTests {
    // MARK: when a run starts

    @Test func nothingRunsWithoutTheSkillBeforeSevenOrWithNudgesOff() async {
        let r = await launch(moodle: nil)  // `robo setup` has not installed the skill
        defer { r.close() }
        serve(r, [courses([courseA])])
        tick(r, at(8))
        #expect(r.window.scout.running == nil && asked(r).isEmpty)
        r.moodle = "https://\(host)"
        tick(r, at(6, 59))  // before 07:00
        #expect(r.window.scout.running == nil && asked(r).isEmpty)
        r.window.nudge.state.enabled = false  // the menu's 🔔 Nudges chip is off
        tick(r, at(8))
        #expect(r.window.scout.running == nil && asked(r).isEmpty)
        r.window.nudge.state.enabled = true
        tick(r, at(8))
        #expect(r.window.scout.running != nil)  // all the gates open: it goes
        #expect(await settled(r))
        #expect(asked(r) == [LMSPosts.listPrompt])
    }

    @Test func aRunOfTheUsersOwnHoldsTheScanBack() async {
        let r = await launch()
        defer { r.close() }
        r.hermes.script = [.wait, .event(.runEnded(status: "completed", output: "ok", error: ""))]
        r.window.ask("what is due?")
        #expect(r.window.busy)
        tick(r, at(8))
        #expect(r.window.scout.running == nil)  // it waits for a free agent
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    // MARK: the day's work

    @Test func theListThenOneCourseAtATimeEachFromItsOwnDayAndEachInASessionOfItsOwn() async throws {
        let r = await launch()
        defer { r.close() }
        serve(r, [courses([courseA, courseB]), fenced([post()]), fenced([post(["course": "PHYS101", "title": "Lab report 2"])])])
        tick(r, at(8))
        #expect(await settled(r))
        #expect(state(r).courses == [courseA, courseB] && state(r).coursesDay == "2026-10-20")
        tick(r, at(8, 1))
        #expect(await settled(r))
        tick(r, at(8, 2))
        #expect(await settled(r))
        tick(r, at(8, 3))
        #expect(r.window.scout.running == nil)  // the day's work is done: nothing starts
        #expect(asked(r) == [
            LMSPosts.listPrompt,
            LMSPosts.scanPrompt(courseA, since: "2026-10-19", today: "2026-10-20"),  // never scanned: one day back, no backfill
            LMSPosts.scanPrompt(courseB, since: "2026-10-19", today: "2026-10-20"),
        ])
        #expect(Set(r.hermes.asked.map(\.session)).count == 3 && r.hermes.asked.allSatisfy { $0.session.hasPrefix("robo-posts-") })
        #expect(state(r).scanned == [courseA.url: "2026-10-20", courseB.url: "2026-10-20"])
        #expect(lmsItems(r).map(\.title) == ["Problem set 4 moved", "Lab report 2"])
        // the files: what a restart would read
        let files = NudgeFiles(dir: r.nudgeDir)
        #expect(files.loadLMS() == state(r) && files.loadAgenda().filter { $0.source == .lms }.count == 2)
        // every run is logged like any other
        let log = try String(contentsOf: r.usage, encoding: .utf8)
        #expect(log.split(separator: "\n").count == 3 && log.contains("completed"))
        // tomorrow: no list needed (it is a day old), and each course reads back to its last good scan
        serve(r, [fenced([])])
        tick(r, at(8, day: 21))
        #expect(await settled(r))
        #expect(asked(r).last == LMSPosts.scanPrompt(courseA, since: "2026-10-20", today: "2026-10-21"))
    }

    @Test func aScanThatFindsADeadlineMakesTheReminderCardWithTheQuoteAndTheWarning() async throws {
        let r = await launch(wall: at(8))
        defer { r.close() }
        serve(r, [courses([courseA]), fenced([post(["due": "2026-10-20T11:00"])])])
        tick(r, at(8))
        #expect(await settled(r))
        tick(r, at(8, 1))
        #expect(await settled(r))
        tick(r, at(8, 2))  // three hours to go: the reminder is due now
        let well = r.window.card.nudge.well.text
        #expect(r.window.nudge.shown.count == 1 && !r.window.card.isHidden)
        #expect(well.hasPrefix("MATH201 · Problem set 4 moved\nin 3 hours · 11:00\n“Problem set 4 is now due Friday 23 October at 23:59.”\nfrom a post: check the date"))
        #expect(r.window.card.nudge.label.text == "HEADS-UP ▸" && well.contains("↗ \(host)"))
    }

    @Test func aDeadlineFoundInAPostIsAnnouncedAtTheNextSlotAsNewAndNotAgain() async {
        let r = await launch()
        defer { r.close() }
        serve(r, [courses([courseA]), fenced([post(["due": "2026-10-25T23:59"])])])  // due Sunday, five days ahead
        tick(r, at(8))
        #expect(await settled(r))
        tick(r, at(8, 1))
        #expect(await settled(r))
        #expect(r.window.nudge.shown.isEmpty)  // 08:01 is no slot: it waits for 09:00
        tick(r, at(9))
        let well = r.window.card.nudge.well.text
        #expect(r.window.nudge.shown.count == 1 && r.window.card.nudge.label.text == "HEADS-UP ▸")
        #expect(well.hasPrefix("MATH201 · Problem set 4 moved\nnew · Sun 23:59\n“Problem set 4 is now due Friday 23 October at 23:59.”\nfrom a post: check the date"))
        r.window.nudge.shown = []  // the card goes away
        r.window.closeBubble()
        tick(r, at(13))  // the same find the next slot: announced already, its day rung is not yet due
        #expect(r.window.nudge.shown.isEmpty)
    }

    @Test func earlierFindingsStayAndAThingFoundAgainIsTheNewOne() async {
        let r = await launch()
        defer { r.close() }
        serve(r, [courses([courseA]), fenced([post(["title": "Lab report 2", "due": "2026-10-22T23:59"]), post()])])
        tick(r, at(8))
        #expect(await settled(r))
        tick(r, at(8, 1))
        #expect(await settled(r))
        #expect(lmsItems(r).count == 2)
        // the next day's scan: one thing moved (same course and title), nothing else was posted
        serve(r, [fenced([post(["title": "Lab report 2!", "posted": "2026-10-20", "due": "2026-10-26T23:59"])])])
        tick(r, at(8, day: 21))
        #expect(await settled(r))
        let items = lmsItems(r)
        #expect(items.count == 2)  // the problem set of the first day stayed, the lab report is one item
        let lab = items.first { $0.title.hasPrefix("Lab report") }
        #expect(lab?.when == Date(timeIntervalSince1970: at(23, 59, day: 26)) && lab?.changed == true)
    }

    // MARK: what a run may do

    @Test func everyAskOfAScanIsDeniedAtOnceAndNoCardShows() async {
        let r = await launch()
        defer { r.close() }
        r.hermes.script = [.event(.approvalNeeded("terminal: rm -rf notes", desktop: false, id: "ask1")),
                           .event(.approvalNeeded("click Submit", desktop: true, id: "ask2")),
                           .event(.runEnded(status: "completed", output: courses([courseA]), error: ""))]
        tick(r, at(8))
        #expect(await settled(r))
        #expect(await pump(r.hermes.approved.count == 2))
        #expect(r.hermes.approved.map(\.id) == ["ask1", "ask2"] && r.hermes.approved.allSatisfy { $0.choice == .deny })
        #expect(r.window.approvals.isEmpty && r.window.card.isHidden)  // nobody was asked
        #expect(state(r).courses == [courseA])  // the run itself went on
    }

    @Test func theUsersRequestStopsTheScanAndCountsNothingAgainstIt() async {
        let r = await launch()
        defer { r.close() }
        r.hermes.script = [.wait, .event(.runEnded(status: "completed", output: courses([courseA]), error: ""))]
        tick(r, at(8))
        #expect(await pump(asked(r).count == 1))
        r.window.ask("hello")  // the user comes first
        #expect(await pump(r.hermes.stopped.contains("run_1")))
        r.hermes.gate.signal()
        r.hermes.gate.signal()
        #expect(await settled(r))
        #expect(await pump(!r.window.busy))
        #expect(state(r).courses.isEmpty && state(r).coursesDay.isEmpty)  // a cancelled reply is not used
        #expect(r.window.scout.failures.isEmpty && r.window.scout.retryAt == 0)  // and is no failure: the next tick goes on
        r.hermes.script = completed(courses([courseA]))
        tick(r, at(8, 2))
        #expect(await settled(r) && state(r).courses == [courseA])
    }

    @Test func aRunThatNeverEndsIsStoppedAtTheLimit() async {
        let r = Rig()
        defer { r.close() }
        r.hermes.script = [.wait]  // never answers
        let scout = Scout(hermes: r.hermes)
        let hermes = r.hermes
        let run = Task { await scout.run("MODE: list", session: "robo-posts-test", limit: 0.2) }
        #expect(await pump(hermes.stopped == ["run_1"], timeout: 3))  // the limit asked Hermes to stop it
        hermes.gate.signal()  // and Hermes ends a stopped run (the fake does not on its own)
        let reply = await run.value
        #expect(reply.status == "timed out" && !reply.cancelled)
    }

    @Test func theTokenCapStopsTheScanLikeAnyOtherRun() async {
        let r = await launch()
        defer { r.close() }
        serve(r, [courses([courseA])])
        r.window.machine.dailyTokens = 50
        Usage.append(Usage.line(UsageRecord(total: 100), status: "completed", seconds: 1, steps: 0, wall: at(7)), to: r.usage)
        tick(r, at(8))
        #expect(r.window.scout.running == nil && asked(r).isEmpty)
        r.window.machine.dailyTokens = 0  // no cap
        tick(r, at(8, 1))
        #expect(await settled(r) && asked(r).count == 1)
    }

    // MARK: what goes wrong

    @Test(arguments: [
        "I'm not signed in to Moodle. Please run `robo signin`, then ask me again.",  // the skill's own sentence: no block
        "```json\n{\"courses\": []}\n```",  // not a list
        courses([courseA]) + "\n```json\n[]\n```",  // two blocks: a post may have talked to the agent
    ])
    func aReplyThatIsNotOneListIsAFailureTriedAgainInHalfAnHourAndThreeTimesADayAtMost(reply: String) async {
        let r = await launch()
        defer { r.close() }
        serve(r, [reply])
        tick(r, at(8))
        #expect(await settled(r))
        #expect(state(r).courses.isEmpty && r.window.scout.failures["list"] == 1)
        tick(r, at(8, 20))  // too early
        #expect(r.window.scout.running == nil && asked(r).count == 1)
        tick(r, at(8, 31))
        #expect(await settled(r))
        tick(r, at(9, 2))
        #expect(await settled(r))
        #expect(r.window.scout.failures["list"] == 3 && asked(r).count == 3)
        tick(r, at(9, 40))
        #expect(r.window.scout.running == nil && asked(r).count == 3)  // enough for today
        tick(r, at(8, day: 21))  // tomorrow it tries again
        #expect(r.window.scout.running != nil)
        #expect(await settled(r))
        #expect(asked(r).count == 4)
    }

    @Test func aFailedRunIsNotUsedEvenWithAGoodLookingAnswer() async {
        let r = await launch()
        defer { r.close() }
        r.hermes.script = [.event(.runEnded(status: "failed", output: courses([courseA]), error: "boom"))]
        tick(r, at(8))
        #expect(await settled(r))
        #expect(state(r).courses.isEmpty && r.window.scout.failures["list"] == 1)
    }

    @Test func aCourseThatKeepsFailingDoesNotHoldTheOthersUp() async {
        let r = await launch()
        defer { r.close() }
        serve(r, [courses([courseA, courseB]), "no luck", "no luck", "no luck", fenced([post(["course": "PHYS101", "title": "Lab report 2"])])])
        for wall in [at(8), at(8, 1), at(8, 32), at(9, 3)] {  // the list, then A three times
            tick(r, wall)
            #expect(await settled(r))
        }
        #expect(r.window.scout.failures[courseA.url] == 3 && state(r).scanned.isEmpty)
        tick(r, at(9, 40))
        #expect(await settled(r))
        #expect(asked(r).last == LMSPosts.scanPrompt(courseB, since: "2026-10-19", today: "2026-10-20"))
        #expect(state(r).scanned == [courseB.url: "2026-10-20"] && lmsItems(r).count == 1)
    }

    @Test func aScanWithNothingUsableKeepsWhatWasThereAndLeavesTheCourseForARetry() async {
        let r = await launch()
        defer { r.close() }
        serve(r, [courses([courseA]), fenced([post()]), "```json\n[1, 2]\n```", "garbage"])
        tick(r, at(8))
        #expect(await settled(r))
        tick(r, at(8, 1))
        #expect(await settled(r))
        #expect(lmsItems(r).count == 1)
        tick(r, at(8, day: 21))  // a list of things that are not objects: nothing found, every one dropped, but the reply was a list
        #expect(await settled(r))
        #expect(lmsItems(r).count == 1 && state(r).scanned[courseA.url] == "2026-10-21")  // the old finding stays
        tick(r, at(8, day: 22))  // garbage: a failure, the course stays unscanned for that day
        #expect(await settled(r))
        #expect(lmsItems(r).count == 1 && state(r).scanned[courseA.url] == "2026-10-21" && r.window.scout.failures[courseA.url] == 1)
    }

    @Test func aListWithNoCoursesIsNotAskedForAgainTheSameDay() async {
        let r = await launch()
        defer { r.close() }
        serve(r, ["No courses.\n\n```json\n[]\n```"])
        tick(r, at(8))
        #expect(await settled(r))
        #expect(state(r).courses.isEmpty && state(r).coursesDay == "2026-10-20" && r.window.scout.failures.isEmpty)
        for wall in [at(8, 1), at(9), at(20)] { tick(r, wall) }  // every 30 s tick of the day
        #expect(r.window.scout.running == nil && asked(r).count == 1)
        tick(r, at(8, day: 21))  // tomorrow it looks again
        #expect(await settled(r))
        #expect(asked(r).count == 2)
    }

    @Test func theListRefreshDropsTheScanDaysOfCoursesThatAreGone() async {
        let r = await launch()
        defer { r.close() }
        serve(r, [courses([courseA, courseB]), fenced([]), fenced([]), courses([courseA])])
        for wall in [at(8), at(8, 1), at(8, 2)] {
            tick(r, wall)
            #expect(await settled(r))
        }
        #expect(state(r).scanned.count == 2)
        tick(r, at(8, day: 28))  // a week later the list is read again; B is no longer there
        #expect(await settled(r))
        #expect(state(r).courses == [courseA] && Set(state(r).scanned.keys) == [courseA.url])
    }

    // MARK: an empty answer from an agent that could not read is not "nothing new"

    @Test(arguments: [
        "Announcements has no post since 28 Sept. I couldn't load the recent-activity view back to 21 Oct because that request was blocked.",  // 2026-10-22
        "I couldn't finish this scan. My click to open the Announcements forum was denied, so I stopped.",  // 2026-10-21
    ])
    func anEmptyListFromAnAgentThatCouldNotReadIsNoScanAndIsTriedAgain(sentence: String) async {
        let r = await launch()
        defer { r.close() }
        serve(r, [courses([courseA]), said(sentence), fenced([])])
        tick(r, at(8))
        #expect(await settled(r))
        tick(r, at(8, 1))
        #expect(await settled(r))
        #expect(state(r).scanned.isEmpty && r.window.scout.failures[courseA.url] == 1)  // not marked read: nothing is skipped for good
        tick(r, at(8, 20))  // too early
        #expect(r.window.scout.running == nil && asked(r).count == 2)
        tick(r, at(8, 32))
        #expect(await settled(r))
        #expect(state(r).scanned == [courseA.url: "2026-10-20"] && asked(r).count == 3)
        #expect(asked(r)[1] == asked(r)[2])  // the retry reads the same days: SINCE did not move
    }

    @Test func anIncompleteReplyKeepsNothingItHolds() async {
        let r = await launch()
        defer { r.close() }
        serve(r, [courses([courseA]), said("INCOMPLETE: the recent-activity page was refused.", [post(), material()])])
        for wall in [at(8), at(8, 1)] {
            tick(r, wall)
            #expect(await settled(r))
        }
        #expect(lmsItems(r).isEmpty && state(r).materials.isEmpty && state(r).scanned.isEmpty)
    }

    @Test func aCourseListThatSaysAClickWasDeniedIsNotKept() async {
        let r = await launch()
        defer { r.close() }
        serve(r, [said("Only one course URL was confirmed, because my click to open the next course was denied.", [["name": courseA.name, "url": courseA.url]])])
        tick(r, at(8))
        #expect(await settled(r))
        #expect(state(r).courses.isEmpty && r.window.scout.failures["list"] == 1)
    }

    // MARK: new learning materials

    @Test func aNewMaterialIsKeptListedInTheVaultAndOfferedAsOneCardADay() async throws {
        let r = await launch()
        defer { r.close() }
        let lab = material(["course": "PHYS101", "post_url": courseB.url, "title": "Lab 3 notebook", "quote": "Added File: Lab 3 notebook"])
        serve(r, [courses([courseA, courseB]), fenced([post(), material()]), fenced([lab])])
        for wall in [at(8), at(8, 1)] {
            tick(r, wall)
            #expect(await settled(r))
        }
        // the first course: the deadline goes to the agenda, the material is only told
        #expect(lmsItems(r).count == 1 && state(r).materials.map(\.title) == ["Lecture 5 slides"])
        let note = r.vault.appendingPathComponent("Radar/Courses-2026-10-20.md")
        let text = try String(contentsOf: note, encoding: .utf8)
        #expect(text.contains("[Lecture 5 slides](\(courseA.url)) · MATH201 · added 2026-10-20") && text.contains("“Updated File: Lecture 5 slides”"))
        var offers = r.window.radar.state.offers.filter { $0.category == .course }
        #expect(offers.count == 1 && offers[0].title == "1 new course material" && offers[0].detail == "Lecture 5 slides")
        #expect(offers[0].id == "lms-materials-2026-10-20" && offers[0].note == "Radar/Courses-2026-10-20.md")
        // the second course, the same day: the same card for two, and the note holds both
        tick(r, at(8, 2))
        #expect(await settled(r))
        offers = r.window.radar.state.offers.filter { $0.category == .course }
        #expect(offers.count == 1 && offers[0].title == "2 new course materials")
        #expect(try String(contentsOf: note, encoding: .utf8).contains("Lab 3 notebook"))
        // a restart reads the same, and the offer is a candidate of the radar's card with the note Open shows
        #expect(NudgeFiles(dir: r.nudgeDir).loadLMS() == state(r) && NudgeFiles(dir: r.nudgeDir).loadRadar(now: Date(timeIntervalSince1970: at(8))) == r.window.radar.state)
        r.window.machine.radarOn = true
        let candidates = r.window.radarCandidates(Date(timeIntervalSince1970: at(9)))
        #expect(candidates.map(\.category) == [.course] && candidates[0].note == "Radar/Courses-2026-10-20.md")
        #expect(Radar.noteURL(candidates[0].note ?? "", vault: r.vault) == note)  // the path Open is allowed to show
    }

    @Test func aMaterialIsToldOnceWhateverTheNextScansSayAboutIt() async {
        let r = await launch()
        defer { r.close() }
        let reading = material(["title": "Reading list", "quote": "Added URL: Reading list"])
        serve(r, [courses([courseA]), fenced([material()]), fenced([material(), reading])])
        for wall in [at(8), at(8, 1)] {
            tick(r, wall)
            #expect(await settled(r))
        }
        #expect(state(r).materials.count == 1)
        tick(r, at(8, day: 21))  // the same slides again, and a new reading
        #expect(await settled(r))
        #expect(state(r).materials.map(\.title).sorted() == ["Lecture 5 slides", "Reading list"])
        let offers = r.window.radar.state.offers.filter { $0.category == .course }.sorted { $0.id < $1.id }
        #expect(offers.map(\.id) == ["lms-materials-2026-10-20", "lms-materials-2026-10-21"])
        #expect(offers[1].title == "1 new course material" && offers[1].detail == "Reading list")  // only the new one
    }

    @Test func aScanWithNothingNewMakesNoCardAndNoNote() async {
        let r = await launch()
        defer { r.close() }
        serve(r, [courses([courseA]), fenced([post()])])
        for wall in [at(8), at(8, 1)] {
            tick(r, wall)
            #expect(await settled(r))
        }
        #expect(r.window.radar.state.offers.filter { $0.category == .course }.isEmpty && state(r).materials.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: r.vault.appendingPathComponent("Radar").path))
    }

    @Test func aMaterialsWordsCannotBecomeMarkupInTheNote() async throws {
        let r = await launch()
        defer { r.close() }
        serve(r, [courses([courseA]), fenced([material(["title": "[free](https://evil.example/x) **now** #tag", "quote": "![i](https://evil.example/p.png) %% hide %%"])])])
        for wall in [at(8), at(8, 1)] {
            tick(r, wall)
            #expect(await settled(r))
        }
        let text = try String(contentsOf: r.vault.appendingPathComponent("Radar/Courses-2026-10-20.md"), encoding: .utf8)
        #expect(text.contains(#"\[free\]"#) && text.contains(#"\*\*now\*\*"#) && text.contains("\\#tag") && text.contains(#"\%\%"#))
        #expect(!text.contains("https://evil") && text.contains(#"https\://evil.example"#))  // no word of it is a link
    }
}

@Suite struct ScoutCardTextTests {
    private func candidate(_ detail: String) -> NudgeCandidate {
        NudgeCandidate(id: "k", category: .deadline, title: "MATH201 · Problem set", detail: detail, url: "https://\(host)/mod/forum/discuss.php?d=1")
    }

    @Test func aMergedCardListsOnlyTheFirstLineOfEachDetail() {
        let one = NudgeText([candidate("today 11:00\n“quote”\nfrom a post: check the date")])
        #expect(one.lines == ["today 11:00\n“quote”\nfrom a post: check the date"] && one.domain == host)
        let many = NudgeText([candidate("today 11:00\n“quote”\nfrom a post: check the date"), candidate("tomorrow 09:00")])
        #expect(many.lines == ["MATH201 · Problem set · today 11:00", "MATH201 · Problem set · tomorrow 09:00"])
    }
}
