// The deadline nudges, end to end through the window: a fake calendar fetch hands in an ICS, the wall clock is a fake (UTC, so the
// slots 09:00 / 13:00 / 19:00 are exact), and the files are in the rig's temp home. Nothing here reads the real link file or
// data folder, the network or a real alert; the rig's `openedLinks` records what Open would have opened.
// 2026-10-20 is a Tuesday.
import AppKit
import Foundation
import Testing
import RoboCore
import RoboSystem
@testable import RoboUI

private let utc = TimeZone(identifier: "UTC")!

/// Seconds since 1970 of 2026-10-`day` at h:m UTC.
private func at(_ h: Int, _ m: Int = 0, day: Int = 20) -> Double {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = utc
    return cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!.timeIntervalSince1970
}

private func date(_ h: Int, _ m: Int = 0, day: Int = 20) -> Date { Date(timeIntervalSince1970: at(h, m, day: day)) }

private func icsTime(_ t: Double) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = utc
    f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return f.string(from: Date(timeIntervalSince1970: t))
}

private func vevent(_ uid: String, _ summary: String, _ start: Double, link: String? = nil) -> String {
    "BEGIN:VEVENT\r\nUID:\(uid)\r\nSUMMARY:\(summary)\r\nDTSTART:\(icsTime(start))\r\n"
        + (link.map { "DESCRIPTION:Open \($0)\r\n" } ?? "") + "END:VEVENT\r\n"
}

private func calendar(_ events: String...) -> String { "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//test//EN\r\n" + events.joined() + "END:VCALENDAR\r\n" }

private let quizLink = "https://moodle.example.edu/mod/quiz/view.php?id=7"
/// An exam tomorrow at 09:00 (with a link) and a meeting the day after.
private let exam = vevent("exam-1", "MATH201 midterm exam", at(9, day: 21), link: quizLink)
private let standup = vevent("sync-1", "Team standup", at(15, day: 22))
private let feed = calendar(exam, standup)

/// A window with the calendar fetch answered, at wall time `wall`.
@MainActor private func launch(_ ics: String?, at wall: Double = at(8, 30), script: [FakeHermes.Step] = [], cps: Double = 0) async -> Rig {
    let r = Rig(script, cps: cps)
    r.fake.wall = wall
    r.fake.ics = ics
    #expect(await pump(r.window.nudge.started && !r.window.nudge.refreshing))
    return r
}

/// What the tick that runs every 30 s would do at wall time `wall`.
@MainActor private func tick(_ r: Rig, _ wall: Double) {
    r.fake.wall = wall
    r.window.nudgeTick()
}

/// The exam's nudge, up on the card at 09:00 (the day-before reminder: its week-before one is covered by it).
@MainActor private func examNudge(script: [FakeHermes.Step] = []) async -> Rig {
    let r = await launch(feed, script: script)
    tick(r, at(9))
    #expect(r.window.nudge.shown.count == 1 && !r.window.card.isHidden)
    return r
}

@MainActor private func files(_ r: Rig) -> NudgeFiles { NudgeFiles(dir: r.nudgeDir) }

// MARK: - when it shows

@MainActor @Suite(.serialized) struct NudgeTimingTests {
    @Test func theExamShowsAtTheNineOClockSlotAndNotBefore() async {
        let r = await launch(feed)
        defer { r.close() }
        #expect(r.window.nudge.agenda.map(\.title) == ["MATH201 midterm exam", "Team standup"] && r.fake.fetches == 1)
        for before in [at(8, 30), at(8, 59) + 59] {
            tick(r, before)
            #expect(r.window.card.isHidden && r.window.nudge.shown.isEmpty, "\(before)")
        }
        tick(r, at(9))
        let w: RoboWindow = r.window
        #expect(!w.card.isHidden && w.nudge.shown.count == 1 && !w.card.nudge.isHidden)
        #expect(w.card.nudge.label.text == "HEADS-UP ▸" && !w.card.nudge.open.isHidden)
        #expect(w.card.nudge.well.text == "MATH201 midterm exam\ntomorrow 09:00\n↗ moodle.example.edu")
        #expect(w.mind.emotion == "concerned" && w.closeAt != 0 && w.closeAfter == 60)
        // the tick that is not due yet does nothing, and one that is due finds the card held
        tick(r, at(9, 1))
        #expect(w.nudge.shown.count == 1 && w.nudge.state.sentToday == 1)
    }

    @Test func itIsSavedTheMomentItShowsAndASecondWindowStartsFromIt() async {
        let r = await examNudge()
        defer { r.close() }
        let w: RoboWindow = r.window
        let exam = w.nudge.agenda.first { $0.title.contains("midterm") }!
        let fired = files(r).loadFired(now: date(9))
        // shown: the reminder, and the looser one it stands for (the week before), and the two first-import marks
        #expect(fired.imported && fired.keys.keys.contains(Reminders.key(exam, .day)) && fired.keys.keys.contains(Reminders.key(exam, .week)))
        #expect(fired.keys.keys.contains(Reminders.key(exam, .newEvent)))
        let state = files(r).loadNudges()
        #expect(state.sentToday == 1 && state.slotsUsed == [9] && state.shown.count == 1 && state.day == "2026-10-20")
        w.closeBubble()
        // a restart: everything is read from the files, and the same nudge does not come back
        w.nudge = NudgeModel()
        w.startNudges()
        #expect(w.nudge.state.sentToday == 1 && w.nudge.agenda.count == 2 && w.nudge.fired.keys == fired.keys)
        #expect(await pump(!w.nudge.refreshing))
        tick(r, at(9, 5))
        #expect(w.card.isHidden && w.nudge.shown.isEmpty)
    }

    @Test func theWallClockDecidesNotTheMonotonicOne() async {
        let r = await launch(feed)
        defer { r.close() }
        r.clock.advance(6 * 3600)  // the monotonic clock moved (or would have stopped in sleep): nothing to do with it
        tick(r, at(8, 40))
        #expect(r.window.nudge.shown.isEmpty)
        r.fake.wall = at(9)
        r.window.nudge.checkAt = 0
        r.window.tick()  // the 100 ms tick takes it from the hook, once its 30 s are due
        #expect(r.window.nudge.shown.count == 1 && r.window.nudge.checkAt == at(9) + 30)
    }

    @Test func aThreeHourWarningShowsAtOnceAndAMeetingHalfAnHourBefore() async {
        let r = await launch(calendar(vevent("m", "Project sync", at(11)), vevent("q", "Quiz 1 deadline", at(11, 30))), at: at(7, 30))
        defer { r.close() }
        tick(r, at(8, 29))  // 08:29 is before 08:30 (the deadline's three hours); quiet hours end at 08:00 and no slot is open
        #expect(r.window.nudge.shown.isEmpty)
        tick(r, at(8, 30))  // urgent: no slot needed
        #expect(r.window.nudge.shown.map(\.candidate.title) == ["Quiz 1 deadline"] && r.window.nudge.shown[0].candidate.urgent)
        #expect(r.window.card.nudge.well.text == "Quiz 1 deadline\nin 3 hours · 11:30")
        r.window.closeBubble()
        tick(r, at(10, 30))  // the meeting, 30 minutes before
        #expect(r.window.nudge.shown.map(\.candidate.title) == ["Project sync"])
        #expect(r.window.card.nudge.well.text == "Project sync\nin 30 min · 11:00" && r.window.mind.emotion == "curious")
    }

    @Test func quietHoursHoldItUntilEightEvenForTheLastHours() async {
        let r = await launch(calendar(vevent("q", "Quiz 1 deadline", at(9, day: 21))), at: at(22, 30))  // due 09:00 tomorrow
        defer { r.close() }
        tick(r, at(22, 30))  // the day-before reminder is long due, and it is night
        tick(r, at(3, day: 21))  // the three hours are on at 06:00 (urgent), but not before 08:00
        tick(r, at(7, 59, day: 21))
        #expect(r.window.nudge.shown.isEmpty && r.window.card.isHidden)
        tick(r, at(8, day: 21))
        #expect(r.window.nudge.shown.count == 1 && r.window.card.nudge.well.text == "Quiz 1 deadline\nin 60 min · 09:00")
    }

    @Test func theCardKeepsAnUnansweredNudgeForAMinuteThenClosesIt() async {
        let r = await examNudge()
        defer { r.close() }
        r.clock.advance(59)
        r.window.tick()
        #expect(!r.window.card.isHidden && r.window.nudge.shown.count == 1)
        r.clock.advance(2)
        r.window.tick()
        #expect(r.window.card.isHidden && r.window.nudge.shown.isEmpty)
        let state = files(r).loadNudges()
        #expect(state.mutedUntil.isEmpty && state.snoozedUntil.isEmpty && state.shown.count == 1)  // dismissed, not muted
    }
}

// MARK: - what holds it

enum Hold: String, CaseIterable, Sendable { case card, run, approval, typing, listening, followUp, typer, press, away }

@MainActor @Suite(.serialized) struct NudgeHeldTests {
    private func hold(_ h: Hold, _ r: Rig, on: Bool) {
        let w: RoboWindow = r.window
        switch h {
        case .card: if on { w.open() } else { w.closeBubble() }
        case .run: w.busy = on
        case .approval: w.approvals = on ? [("1", "ls")] : []
        case .typing: if on { w.feed(String(repeating: "word ", count: 40)) } else { w.skip() }
        case .listening: w.mind = w.mind.react(.listening(on), now: w.now())
        case .followUp: w.followUntil = on ? w.now() + 10 : 0
        case .typer: if on { w.typeText() } else { r.typers.last?.close() }
        case .press: w.press = on ? Vec.zero : nil
        case .away: r.away = on
        }
    }

    @Test(arguments: Hold.allCases) func eachOfTheseKeepsTheNudgeBackUntilItIsOver(_ h: Hold) async {
        let r = await launch(feed, cps: 30)
        defer { r.close() }
        hold(h, r, on: true)
        tick(r, at(9, 5))  // the slot is open, the reminder is due
        #expect(r.window.nudge.shown.isEmpty && r.window.card.nudge.isHidden, "\(h)")
        #expect(r.window.nudge.state.sentToday == 0, "\(h): a held tick is not a use of the budget")
        hold(h, r, on: false)
        tick(r, at(9, 6))
        #expect(r.window.nudge.shown.count == 1 && !r.window.card.nudge.isHidden, "\(h) was released")
    }

    @Test func aLiveRunOrAnAnswerOnTheCardIsNeverBrokenInOn() async {
        let r = await launch(feed, script: [completed("The answer is 42.")])
        defer { r.close() }
        r.window.ask("what is six times seven")
        #expect(await pump(!r.window.busy))
        #expect(!r.window.card.isHidden)  // the answer is up for 20 s
        tick(r, at(9, 5))
        #expect(r.window.nudge.shown.isEmpty && r.window.card.nudge.isHidden && r.window.tw.text == "The answer is 42.")
    }

    @Test func nudgesTurnedOffShowNothingAndStayOffAcrossARestart() async {
        let r = await launch(feed)
        defer { r.close() }
        r.window.showMenu()
        #expect(r.window.card.chips.nudges.title == "🔔 Nudges" && r.window.card.chips.height == 62)
        r.window.menu(.nudges)
        #expect(!r.window.nudge.state.enabled && !files(r).loadNudges().enabled)
        r.window.showMenu()
        #expect(r.window.card.chips.nudges.title == "🔕 Nudges" && r.window.card.chips.height == 62)  // the menu keeps its height
        r.window.closeBubble()
        tick(r, at(9))
        #expect(r.window.nudge.shown.isEmpty)
        r.window.nudge = NudgeModel()
        r.window.startNudges()
        #expect(!r.window.nudge.state.enabled)
        #expect(await pump(!r.window.nudge.refreshing))
        r.window.menu(.nudges)  // on again: the reminder that waited shows
        tick(r, at(9, 5))
        #expect(r.window.nudge.state.enabled && r.window.nudge.shown.count == 1)
    }
}

// MARK: - the answers

@MainActor @Suite(.serialized) struct NudgeAnswerTests {
    @Test func laterBringsItBackAtTheNextSlot() async {
        let r = await examNudge()
        defer { r.close() }
        let id = r.window.nudge.shown[0].candidate.id
        r.window.card.nudge.later.onClick?()
        #expect(r.window.card.isHidden && r.window.nudge.shown.isEmpty && r.window.card.nudge.isHidden)
        let state = files(r).loadNudges()
        #expect(state.snoozedUntil[id] == date(13) && state.shown[id] == nil && state.mutedUntil.isEmpty)
        #expect(!files(r).loadFired(now: date(9)).keys.keys.contains(id))  // handed back: its reminder is due again
        tick(r, at(12, 59))
        #expect(r.window.nudge.shown.isEmpty)
        tick(r, at(13))
        #expect(r.window.nudge.shown.map(\.candidate.id) == [id])
        #expect(files(r).loadNudges().sentToday == 2 && files(r).loadNudges().slotsUsed == [9, 13])
    }

    @Test func notForMeSilencesItForAMonthAndKeepsTheStreak() async {
        let r = await examNudge()
        defer { r.close() }
        let id = r.window.nudge.shown[0].candidate.id
        r.window.card.nudge.notForMe.onClick?()
        #expect(r.window.card.isHidden && r.window.nudge.shown.isEmpty)
        let state = files(r).loadNudges()
        #expect(state.mutedUntil[id] == date(9).addingTimeInterval(30 * 86_400) && state.notForMeStreak["deadline"] == 1)
        #expect(files(r).loadFired(now: date(9)).keys.keys.contains(id))  // and it is not handed back
        for slot in [13, 19] {
            tick(r, at(slot))
            #expect(r.window.nudge.shown.isEmpty, "slot \(slot)")
        }
    }

    @Test func openAsksFirstThenOpensTheLinkAndTheCardGoes() async {
        let r = await examNudge()
        defer { r.close() }
        let url = URL(string: quizLink)!
        r.linkAnswer = false  // the alert says no: the nudge is still there, nothing opened, nothing resolved
        r.window.card.nudge.open.onClick?()
        #expect(r.linkAsks == [url] && r.openedLinks.isEmpty && r.window.nudge.shown.count == 1 && !r.window.card.isHidden)
        r.linkAnswer = true
        r.window.card.nudge.open.onClick?()
        #expect(r.linkAsks == [url, url] && r.openedLinks == [url] && r.window.card.isHidden && r.window.nudge.shown.isEmpty)
        let state = files(r).loadNudges()
        #expect(state.mutedUntil.isEmpty && state.snoozedUntil.isEmpty && state.notForMeStreak["deadline"] == 0 && state.shown.count == 1)
        tick(r, at(13))
        #expect(r.window.nudge.shown.isEmpty)  // opened is answered for good
    }

    @Test func aLinkThatIsNotHttpsIsNeverOffered() {
        for link in ["http://moodle.example.edu/x", "javascript:alert(1)", "file:///etc/passwd", "mailto:a@b.c", "moodle.example.edu", "https://"] {
            #expect(Nudges.openable(link) == nil, "\(link)")
        }
        #expect(Nudges.openable(quizLink) == URL(string: quizLink))
    }

    enum Way: String, CaseIterable, Sendable { case closeBubble, escape, faceClick, timeout, listening, ask, say }

    @Test(arguments: Way.allCases) func everyOtherWayTheCardEndsIsDismissedNeverMuted(_ way: Way) async {
        let r = await examNudge(script: [completed("Hi.")])
        defer { r.close() }
        let w: RoboWindow = r.window
        let id = w.nudge.shown[0].candidate.id
        switch way {
        case .closeBubble: w.closeBubble()
        case .escape: w.escape()
        case .faceClick: w.clicked()
        case .timeout:
            r.clock.advance(61)
            w.tick()
        case .listening: w.onEvent(.listening(true))
        case .ask:
            w.ask("hello")
            #expect(await pump(!w.busy))
        case .say: w.say("Sorry, I didn't catch that.")
        }
        #expect(w.nudge.shown.isEmpty && w.card.nudge.isHidden, "\(way)")
        let state = files(r).loadNudges()
        #expect(state.mutedUntil.isEmpty && state.snoozedUntil.isEmpty && state.mutedCategories.isEmpty && state.notForMeStreak.isEmpty, "\(way)")
        #expect(state.shown[id] != nil, "\(way): seen, so it does not come back")
        tick(r, at(13))
        #expect(w.nudge.shown.isEmpty, "\(way)")
    }
}

// MARK: - what it is made of

@MainActor @Suite(.serialized) struct NudgeAgendaTests {
    @Test func severalDueAtOnceMakeOneCard() async {
        let r = await launch(calendar(vevent("a", "Assignment 1 is due", at(8, day: 21)), vevent("b", "Assignment 2 is due", at(8, 30, day: 21)),
                                      vevent("c", "Assignment 3 is due", at(8, 45, day: 21)), vevent("far", "Assignment 9 is due", at(8, day: 30))))
        defer { r.close() }
        tick(r, at(9))
        let w: RoboWindow = r.window
        #expect(w.nudge.shown.count == 3 && w.card.nudge.well.text.hasPrefix("3 things due soon\nAssignment 1 is due · tomorrow 08:00\nAssignment 2 is due · tomorrow 08:30\nAssignment 3 is due · tomorrow 08:45"))
        #expect(w.card.nudge.open.isHidden && w.nudge.state.sentToday == 1)  // one nudge of the day's three
        let fired = files(r).loadFired(now: date(9)).keys.keys
        #expect(w.nudge.agenda.prefix(3).allSatisfy { fired.contains(Reminders.key($0, .day)) })
        w.card.nudge.later.onClick?()  // later takes all three back
        let state = files(r).loadNudges()
        #expect(state.snoozedUntil.count == 3 && !w.nudge.agenda.prefix(3).contains { files(r).loadFired(now: date(9)).keys.keys.contains(Reminders.key($0, .day)) })
    }

    @Test func theFirstImportDoesNotAnnounceTheComingWeekButALaterNewEventIsAnnounced() async {
        let r = await launch(feed)
        defer { r.close() }
        let w: RoboWindow = r.window
        #expect(w.nudge.fired.imported && w.nudge.fired.keys.count == 2)  // an announcement mark for each of the two events
        tick(r, at(9))
        #expect(w.nudge.shown.count == 1 && !w.card.nudge.well.text.contains("new in your calendar") && !w.card.nudge.well.text.contains("standup"))
        w.closeBubble()
        r.fake.ics = calendar(exam, standup, vevent("dentist", "Dentist appointment", at(15, day: 21)))
        tick(r, at(10))
        r.window.refreshAgenda()
        #expect(await pump(w.nudge.agenda.count == 3 && !w.nudge.refreshing))
        tick(r, at(13))
        #expect(w.nudge.shown.map(\.candidate.title) == ["Dentist appointment"])
        #expect(w.card.nudge.well.text == "Dentist appointment\nnew in your calendar · tomorrow 15:00" && w.mind.emotion == "curious")
        #expect(w.card.nudge.open.isHidden)  // no link in it
    }

    @Test func anEventThatMovedIsAnnouncedAsMoved() async {
        let r = await launch(feed)
        defer { r.close() }
        r.fake.ics = calendar(exam, vevent("sync-1", "Team standup", at(16, day: 22)))  // an hour later
        r.window.refreshAgenda()
        #expect(await pump(!r.window.nudge.refreshing && r.window.nudge.agenda.last?.changed == true))
        tick(r, at(9))
        #expect(r.window.nudge.shown.count == 2)  // the exam and the moved meeting, one card
        #expect(r.window.card.nudge.well.text.contains("Team standup · moved · Thu 16:00"))
    }

    @Test func aFailedFetchKeepsTheLastGoodAgendaAndSaysNothing() async throws {
        let r = await launch(feed)
        defer { r.close() }
        let w: RoboWindow = r.window
        let before = w.nudge.agenda, bytes = try Data(contentsOf: files(r).agendaFile)
        r.fake.ics = nil
        r.fake.failures = ["calendar: HTTP 403"]
        w.refreshAgenda()
        #expect(await pump(!w.nudge.refreshing && r.fake.fetches == 2))
        let after = try Data(contentsOf: files(r).agendaFile)
        #expect(w.nudge.agenda == before && w.nudge.fired.imported && after == bytes)
        #expect(w.card.isHidden)  // no card, no sound: a failure is one quiet log line
        #expect(w.nudge.refreshAt == at(8, 30) + Nudges.retryS && Nudges.retryS == 300)  // and another try in 5 minutes, not 45
        tick(r, at(8, 36))
        #expect(await pump(!w.nudge.refreshing && r.fake.fetches == 3))  // the retry (it fails again: the agenda is still the old one)
        tick(r, at(9))
        #expect(w.nudge.shown.count == 1)  // and the reminders go on from what it had
        #expect(await pump(!w.nudge.refreshing && r.fake.fetches == 4))
        #expect(w.nudge.agenda == before)
        // when the link is gone altogether (removed), its events go and a new link is a first import again
        w.closeBubble()
        r.fake.failures = []
        w.refreshAgenda()
        #expect(await pump(!w.nudge.refreshing && r.fake.fetches == 5))
        #expect(w.nudge.agenda.isEmpty && !w.nudge.fired.imported)
    }

    @Test func theLedgersExamsAndSnoozeComeFromStudyMd() async throws {
        let r = await launch(nil, at: at(8, 30, day: 21))
        defer { r.close() }
        let w: RoboWindow = r.window
        #expect(w.nudge.agenda.isEmpty)
        try FileManager.default.createDirectory(at: r.nudgeDir, withIntermediateDirectories: true)
        try """
            # Study ledger

            ## Exams
            - 2026-10-11 · MATH201 Linear Algebra midterm · 2026-10-24 09:00

            ## Notes
            - 2026-10-12 · snooze nudges until 2026-10-22
            """.write(to: r.study, atomically: true, encoding: .utf8)
        tick(r, at(9, 5, day: 21))  // the file changed: read again; the snooze holds the nudge back
        #expect(w.nudge.agenda.map(\.id) == ["ledger:math201-linear-algebra-midterm"] && w.nudge.agenda[0].source == .ledger)
        #expect(files(r).loadAgenda().count == 1 && w.nudge.snoozeUntil == date(0, day: 22) && w.nudge.shown.isEmpty)
        tick(r, at(9, day: 22))  // the snooze is over
        #expect(w.nudge.shown.count == 1 && w.card.nudge.well.text == "MATH201 Linear Algebra midterm\nSat 09:00")
    }

    @Test func theCalendarIsFetchedEvery45MinutesOfWallTimeAfterAWakeAndNeverTwiceAtOnce() async {
        let r = await launch(feed)
        defer { r.close() }
        let w: RoboWindow = r.window
        #expect(r.fake.fetches == 1)
        tick(r, at(9, 14))
        #expect(await pump(!w.nudge.refreshing) && r.fake.fetches == 1)  // 44 minutes: not yet
        tick(r, at(9, 16))
        #expect(await pump(r.fake.fetches == 2 && !w.nudge.refreshing))
        w.closeBubble()
        w.nudgeWoke()  // the Mac woke and the user is back: at once, not in 45 minutes
        w.tick()
        #expect(await pump(r.fake.fetches == 3 && !w.nudge.refreshing))
        w.refreshAgenda()
        w.refreshAgenda()  // one fetch at a time
        #expect(await pump(!w.nudge.refreshing))
        #expect(r.fake.fetches == 4)
    }
}

// MARK: - what it must not do

@MainActor @Suite(.serialized) struct NudgeMannersTests {
    @Test func aCardNobodyAskedForNeverRaisesTheScreenRecordingDialog() async {
        let r = await examNudge()
        defer { r.close() }
        #expect(r.screenAsks == 0)
        r.window.closeBubble()
        r.window.say("hello")  // the user's own card asks, once
        #expect(r.screenAsks == 1)
    }

    @Test func theAnimationFollowsTheMachinesReduceMotion() async {
        let r = Rig()
        defer { r.close() }
        let before = r.reduceReads
        r.reduceMotion = true
        r.window.open()
        #expect(r.reduceReads == before + 1 && r.window.card.alphaValue == 1)  // asked the machine, not NSWorkspace
    }

    @Test func aNudgeDoesNotSendThePetToACornerButAReplyDoes() async {
        let r = await launch(feed)
        defer { r.close() }
        let w: RoboWindow = r.window
        w.roamer.pos = Vec(600, 500)
        w.move(to: w.roamer.pos)
        tick(r, at(9))
        #expect(w.nudge.shown.count == 1)
        let here = w.roamer.pos  // the window grew around the face
        for _ in 0..<1300 { r.clock.advance(0.05); w.roam() }  // 65 s: the whole minute the card stays, a drift would have left
        #expect(w.roamer.mode != .come && w.roamer.pos == here && w.windowTopLeft == here)
        w.closeBubble()
        w.say("A reply, for comparison.")
        for _ in 0..<100 { r.clock.advance(0.05); w.roam() }
        #expect(w.roamer.mode == .come)  // an ordinary card calls it to the corner
    }

    @Test func aSleepingPetWakesForANudge() async {
        let r = await launch(feed)
        defer { r.close() }
        r.clock.advance(Mind.asleepAfter + 1)
        r.window.mind = r.window.mind.tick(now: r.window.now())
        #expect(r.window.mind.activity == .asleep)
        tick(r, at(9))
        #expect(r.window.nudge.shown.count == 1 && r.window.mind.activity == .idle && r.window.mind.emotion == "concerned")
    }

    @Test func theTypeWindowIsNotInterruptedAndTheNudgeWaitsForItsClose() async {
        let r = await launch(feed)
        defer { r.close() }
        r.window.typeText()
        #expect(r.window.typerOpen)
        tick(r, at(9))
        #expect(r.window.nudge.shown.isEmpty)
        r.typers[0].cancelled()
        #expect(!r.window.typerOpen)
        r.window.typeText()  // a second one replaces the first; the first one closing does not mark the new one closed
        r.typers[0].close()
        #expect(r.window.typerOpen)
    }
}

// MARK: - the words and the switch

@Suite struct NudgeWordsTests {
    private func when(_ seconds: Double, zone: TimeZone = utc) -> String {
        Nudges.whenText(date(9).addingTimeInterval(seconds), now: date(9), zone: zone)
    }

    @Test func timeIsSaidTheWayAPersonWould() {
        #expect(when(1) == "in 1 min · 09:00" && when(25 * 60) == "in 25 min · 09:25" && when(89 * 60) == "in 89 min · 10:29")
        #expect(when(90 * 60) == "in 2 hours · 10:30" && when(3 * 3600) == "in 3 hours · 12:00")
        #expect(when(9 * 3600) == "today 18:00" && when(24 * 3600) == "tomorrow 09:00" && when(3 * 86_400) == "Fri 09:00")
        #expect(when(7 * 86_400) == "27 Oct 09:00")
        // the user's day, not UTC's: 09:00 UTC is 18:00 in Tokyo, so 15:30 UTC is already tomorrow there
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(when(6.5 * 3600) == "today 15:30" && when(6.5 * 3600, zone: tokyo) == "tomorrow 00:30")
        #expect(when(15 * 3600, zone: tokyo) == "tomorrow 09:00")
    }

    @Test func aReminderBecomesACandidateWithItsKeyAsIdAndItsCategory() {
        func make(_ kind: AgendaItem.Kind, title: String = "Quiz 1", course: String? = nil, changed: Bool = false, at start: Double = at(15, day: 21)) -> AgendaItem {
            AgendaItem(id: "x", title: title, course: course, kind: kind, when: Date(timeIntervalSince1970: start), source: .ics, url: quizLink, firstSeen: date(8), changed: changed)
        }
        func first(_ item: AgendaItem, fired: Set<String> = []) -> Reminder { Reminders.due(items: [item], fired: fired, now: date(9), zone: utc)[0] }
        let fresh = first(make(.event))
        let c = Nudges.candidate(fresh, now: date(9), zone: utc)
        #expect(fresh.rung == .newEvent && c.id == fresh.key && c.category == .event && !c.urgent && c.dueAt == fresh.item.when && c.url == quizLink)
        #expect(c.detail == "new in your calendar · tomorrow 15:00" && c.title == "Quiz 1")
        #expect(Nudges.candidate(first(make(.event, changed: true)), now: date(9), zone: utc).detail == "moved · tomorrow 15:00")
        let exam = first(make(.exam, course: "MATH201", at: at(9, 30)), fired: Set([Reminders.key(make(.exam, at: at(9, 30)), .newEvent)]))
        let e = Nudges.candidate(exam, now: date(9), zone: utc)
        #expect(e.category == .deadline && e.urgent && e.title == "MATH201 · Quiz 1" && e.detail == "in 30 min · 09:30")  // hours3: the last hours
        #expect(Nudges.candidate(first(make(.opportunity)), now: date(9), zone: utc).category == .opportunity)
        #expect(Nudges.candidate(first(make(.deadline, title: "MATH201 quiz is due", course: "MATH201")), now: date(9), zone: utc).title == "MATH201 quiz is due")  // not twice
        #expect(Nudges.candidate(first(make(.deadline, title: String(repeating: "x", count: 500))), now: date(9), zone: utc).title.count == 120)
    }

    @Test func theSnoozeLineIsReadFromTheNotesOnly() {
        func snooze(_ text: String, zone: TimeZone = utc) -> Date? { Nudges.snoozeUntil(in: text, zone: zone) }
        let notes = "# Study ledger\n\n## Notes\n- 2026-10-12 · Snooze Nudges Until 2026-10-26\n- 2026-10-01 · snooze nudges until 2026-10-05\n"
        #expect(snooze(notes) == date(0, day: 26))  // the newest line is first
        #expect(snooze(notes, zone: TimeZone(identifier: "Asia/Tokyo")!) == date(0, day: 26).addingTimeInterval(-9 * 3600))
        #expect(snooze("## Goals\n- 2026-10-12 · snooze nudges until 2026-10-26\n") == nil)  // not in the Notes
        #expect(snooze("## Notes\n- snooze nudges until 2026-02-30\n") == nil && snooze("## Notes\n- snooze nudges until 2026-13-01\n") == nil)
        #expect(snooze("## Notes\n- snooze nudges until tomorrow\n") == nil && snooze("") == nil)
    }

    @Test func theDevSwitchShiftsTheWallClockAndNothingElse() {
        let home = FileManager.default.temporaryDirectory
        func offset(_ value: String?) -> Double {
            let env = value.map { ["ROBO_WALL_OFFSET": $0] } ?? [:]
            return Machine(home: home, environment: env).wall() - Date().timeIntervalSince1970
        }
        #expect(abs(offset("-3600") + 3600) < 5 && abs(offset("7200.5") - 7200.5) < 5 && abs(offset(nil)) < 5)
        for junk in ["", "abc", "inf", "-inf", "nan", "1e999"] { #expect(abs(offset(junk)) < 5, "\(junk)") }
        let env = ["ROBO_WALL_OFFSET": "3600"]
        let m = Machine(home: home, environment: env)
        #expect(abs(m.clock() - ProcessInfo.processInfo.systemUptime) < 5)  // the monotonic clock is not touched
        #expect(Machine.awayS == 300)  // idle longer than five minutes is away
    }

    @Test func theDemoSwitchCountsTheUserAsPresent() {
        let home = FileManager.default.temporaryDirectory
        #expect(Machine(home: home, environment: ["ROBO_NUDGE_PRESENT": "1"]).userAway() == false)
        // anything but "1" leaves the real check (it reads the machine's idle time, so only the switch is asserted here)
    }
}
