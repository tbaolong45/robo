// When a nudge may show: the three slots, quiet hours, the daily caps, urgent nudges, held / off / ledger snooze, digest back-off,
// the contest weekly cap, the opportunity rule, Later / Not for me / Opened / Dismissed, the state file, and the same rules on DST
// days and in a zone other than the machine's. Days are simulated tick by tick; every zone is named.
import Foundation
import Testing
@testable import RoboCore

private let UTC = TimeZone(identifier: "UTC")!
private let VN = TimeZone(identifier: "Asia/Ho_Chi_Minh")!  // the user's zone
private let BERLIN = TimeZone(identifier: "Europe/Berlin")!  // DST ends Sunday 2026-10-25 at 03:00 local
private let NEW_YORK = TimeZone(identifier: "America/New_York")!  // DST starts Sunday 2026-03-08 at 02:00 local

private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ zone: TimeZone = UTC) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

/// A time on a day of October 2026 in Vietnam. 2026-10-20 is a Tuesday; the ISO week 43 is 10-19 to 10-25.
private func vn(_ h: Int, _ m: Int = 0, day: Int = 20) -> Date { at(2026, 10, day, h, m, VN) }

private let FAR = at(2026, 12, 31)  // a due date nothing here gets close to

private func cand(_ id: String, _ category: NudgeCategory = .deadline, urgent: Bool = false, due: Date? = FAR, saved: Bool = false) -> NudgeCandidate {
    NudgeCandidate(id: id, category: category, urgent: urgent, title: "Title \(id)", detail: "why", url: "https://x.example/\(id)", dueAt: due, saved: saved)
}

private func digest(_ id: String = "digest") -> NudgeCandidate { cand(id, .digest, due: nil) }
private func contest(_ id: String = "contest") -> NudgeCandidate { cand(id, .contest, due: nil) }

/// What `next` returns, as ids.
@discardableResult
private func tick(_ state: inout NudgeState, _ cs: [NudgeCandidate], _ now: Date, zone: TimeZone = VN, held: Bool = false, snooze: Date? = nil) -> [String] {
    NudgeBudget.next(state: &state, candidates: cs, now: now, zone: zone, ledgerSnoozeUntil: snooze, held: held).map(\.id)
}

private func answer(_ state: inout NudgeState, _ shown: [NudgeCandidate], _ outcome: NudgeBudget.Outcome, _ now: Date, zone: TimeZone = VN) {
    NudgeBudget.resolve(&state, shown: shown, outcome: outcome, now: now, zone: zone)
}

/// `next` returning the candidates themselves, for the tests that answer the card.
private func show(_ state: inout NudgeState, _ cs: [NudgeCandidate], _ now: Date, zone: TimeZone = VN) -> [NudgeCandidate] {
    NudgeBudget.next(state: &state, candidates: cs, now: now, zone: zone, ledgerSnoozeUntil: nil, held: false)
}

@Suite struct NudgeBudgetTests {
    // MARK: quiet hours and the slots

    /// A normal deadline: only after a slot has opened (09:00, 13:00, 19:00) and never from 22:00 to 08:00. An urgent one:
    /// from 08:00 to 21:59.
    @Test(arguments: [
        (0, 0, false, false), (7, 59, false, false), (8, 0, false, false), (8, 59, false, false), (9, 0, false, true), (11, 30, false, true),
        (12, 59, false, true), (13, 0, false, true), (19, 0, false, true), (21, 59, false, true), (22, 0, false, false), (23, 59, false, false),
        (0, 0, true, false), (3, 0, true, false), (7, 59, true, false), (8, 0, true, true), (8, 30, true, true), (12, 0, true, true),
        (21, 59, true, true), (22, 0, true, false), (23, 59, true, false),
    ] as [(Int, Int, Bool, Bool)])
    func aNudgeShowsOnlyInsideQuietHoursAndSlots(h: Int, m: Int, urgent: Bool, shows: Bool) {
        var state = NudgeState()
        let got = tick(&state, [cand("d", urgent: urgent)], vn(h, m))
        #expect(got == (shows ? ["d"] : []), "\(h):\(m) urgent \(urgent)")
    }

    @Test func eachSlotIsUsedOnceAndAnotherCandidateWaitsForTheNextSlot() {
        var state = NudgeState()
        #expect(tick(&state, [cand("d1")], vn(9, 0)) == ["d1"])
        #expect(tick(&state, [cand("d1"), cand("d2")], vn(9, 1)) == [])
        #expect(tick(&state, [cand("d2")], vn(10, 0)) == [])
        #expect(tick(&state, [cand("d2")], vn(12, 59)) == [])
        #expect(tick(&state, [cand("d2")], vn(13, 0)) == ["d2"])
        #expect(tick(&state, [cand("d3")], vn(13, 30)) == [])
        #expect(tick(&state, [cand("d3")], vn(18, 59)) == [])
        #expect(tick(&state, [cand("d3")], vn(19, 0)) == ["d3"])
        #expect(tick(&state, [cand("d4")], vn(19, 1)) == [])
        #expect(tick(&state, [cand("d4")], vn(21, 59)) == [])
        #expect(state.sentToday == 3 && state.slotsUsed == [9, 13, 19])
    }

    @Test func aSlotStaysOpenUntilTheNextOneSoALaterCandidateStillGetsIt() {
        var state = NudgeState()
        #expect(tick(&state, [], vn(9, 0)) == [])
        #expect(tick(&state, [], vn(10, 0)) == [])
        #expect(tick(&state, [cand("late")], vn(11, 30)) == ["late"])  // slot 09:00 is open until 13:00
        #expect(state.slotsUsed == [9])
        #expect(tick(&state, [cand("next")], vn(12, 0)) == [])
        #expect(tick(&state, [cand("next")], vn(13, 0)) == ["next"])
    }

    @Test func anUnusedSlotIsNotSavedForLater() {
        var state = NudgeState()
        #expect(tick(&state, [], vn(9, 0)) == [] && tick(&state, [], vn(13, 0)) == [])
        #expect(tick(&state, [cand("a")], vn(19, 0)) == ["a"])
        #expect(tick(&state, [cand("b")], vn(20, 0)) == [])  // one slot, one nudge: no catching up for the two that were empty
        #expect(state.sentToday == 1)
    }

    @Test func emptyTicksUseNoSlotAndChangeNoCounter() {
        var state = NudgeState()
        for h in 9...21 { tick(&state, [], vn(h, 0)) }
        #expect(state.sentToday == 0 && state.urgentToday == 0 && state.slotsUsed.isEmpty && state.sentByCategory.isEmpty)
        #expect(tick(&state, [cand("d")], vn(21, 30)) == ["d"])
    }

    @Test func atMostThreeNormalNudgesADay() {
        var state = NudgeState()
        var shown: [String] = []
        for (i, hour) in [9, 13, 19].enumerated() { shown += tick(&state, [cand("d\(i)")], vn(hour, 0)) }
        #expect(shown == ["d0", "d1", "d2"])
        // Even with a slot's worth of time left and fresh candidates, nothing more.
        for m in stride(from: 0, to: 120, by: 5) { #expect(tick(&state, [cand("extra\(m)")], vn(19, 0).addingTimeInterval(Double(m) * 60)) == []) }
        #expect(state.sentToday == 3)
    }

    @Test func aNewDayStartsTheCountersAgainAtLocalMidnightNotUTCs() {
        var state = NudgeState()
        #expect(tick(&state, [cand("a")], vn(19, 0)) == ["a"] && state.day == "2026-10-20")
        // 16:59Z is 23:59 in Vietnam; 17:00Z is already the 21st there.
        tick(&state, [], at(2026, 10, 20, 16, 59))
        #expect(state.day == "2026-10-20" && state.sentToday == 1)
        tick(&state, [], at(2026, 10, 20, 17, 0))
        #expect(state.day == "2026-10-21" && state.sentToday == 0 && state.slotsUsed.isEmpty && state.sentByCategory.isEmpty)
        #expect(tick(&state, [cand("b")], vn(9, 0, day: 21)) == ["b"])
    }

    // MARK: merging and priority

    @Test func everyDeadlineAndEventOfTheMomentIsOneNudgeInTimeOrder() {
        var state = NudgeState()
        let pool = [cand("e1", .event, due: at(2026, 10, 22)), cand("d2", due: at(2026, 10, 23)), cand("d1", due: at(2026, 10, 21)), cand("d0", due: at(2026, 10, 21))]
        #expect(tick(&state, pool, vn(9, 0)) == ["d0", "d1", "e1", "d2"])
        #expect(state.sentToday == 1 && state.sentByCategory == ["deadline": 3, "event": 1])
    }

    @Test func otherCategoriesAreNudgesOfTheirOwnInPriorityOrder() {
        var state = NudgeState()
        let pool = [contest("c"), digest("g"), cand("o", .opportunity, due: nil, saved: true), cand("d1", due: at(2026, 10, 25)), cand("e1", .event, due: at(2026, 10, 24))]
        #expect(tick(&state, pool, vn(9, 0)) == ["e1", "d1"])  // deadlines and events first, together
        #expect(tick(&state, pool, vn(13, 0)) == ["o"])
        #expect(tick(&state, pool, vn(19, 0)) == ["g"])
        #expect(tick(&state, pool, vn(9, 0, day: 21)) == ["c"])  // the contest waits for the next day: three slots are gone
    }

    @Test func aCandidateIsNotShownTwiceEvenIfTheCallerKeepsOfferingIt() {
        var state = NudgeState()
        let d = cand("d")
        #expect(tick(&state, [d], vn(9, 0)) == ["d"])
        for h in [13, 19] { #expect(tick(&state, [d], vn(h, 0)) == []) }
        #expect(tick(&state, [d], vn(9, 0, day: 21)) == [])
    }

    @Test func twoCandidatesWithOneIdAreOne() {
        var state = NudgeState()
        #expect(tick(&state, [cand("d"), cand("d")], vn(9, 0)) == ["d"])
    }

    @Test func aCandidateWhoseTimeHasPassedIsNeverShown() {
        var state = NudgeState()
        #expect(tick(&state, [cand("past", due: vn(9, 0).addingTimeInterval(-1)), cand("now", due: vn(9, 0))], vn(9, 0)) == [])
        #expect(tick(&state, [cand("soon", due: vn(9, 0).addingTimeInterval(1))], vn(9, 0)) == ["soon"])
        var other = NudgeState()
        #expect(tick(&other, [cand("u", urgent: true, due: vn(11, 0))], vn(11, 0)) == [])  // a meeting that has started
        #expect(tick(&other, [cand("u", urgent: true, due: vn(11, 0).addingTimeInterval(60))], vn(11, 0)) == ["u"])
    }

    // MARK: urgent

    @Test func urgentCandidatesShowAtOnceMergedIntoOneAndUseNoSlot() {
        var state = NudgeState()
        let pool = [cand("u1", urgent: true, due: at(2026, 10, 20, 8)), cand("u2", .event, urgent: true, due: at(2026, 10, 20, 5)), cand("n", due: FAR)]
        #expect(tick(&state, pool, vn(11, 0)) == ["u2", "u1"])  // one nudge, soonest first, ahead of the normal one
        #expect(state.urgentToday == 1 && state.sentToday == 0 && state.slotsUsed.isEmpty)
        // The urgent ones are not offered again; the normal one takes the 09:00 slot, which was still open and unused.
        #expect(tick(&state, pool, vn(11, 1)) == ["n"])
        #expect(state.sentToday == 1 && state.slotsUsed == [9] && state.urgentToday == 1)
        #expect(tick(&state, pool, vn(13, 0)) == [])
    }

    @Test func urgentShowsEvenWhenTheSlotsAndTheNormalBudgetAreUsed() {
        var state = NudgeState()
        for (i, h) in [9, 13, 19].enumerated() { tick(&state, [cand("n\(i)")], vn(h, 0)) }
        #expect(state.sentToday == 3)
        #expect(tick(&state, [cand("u", urgent: true)], vn(20, 0)) == ["u"])
        #expect(state.sentToday == 3 && state.urgentToday == 1)
    }

    @Test func atMostFourUrgentNudgesADayAndTheNextOnesBecomeNormalNudgesForASlot() {
        var state = NudgeState()
        // Four urgent nudges between 14:00 and 14:30, each its own card. The slot of 13:00 is open and unused all that time.
        for i in 0..<4 { #expect(tick(&state, [cand("u\(i)", urgent: true)], vn(14, i * 10)) == ["u\(i)"]) }
        #expect(state.urgentToday == 4 && state.sentToday == 0)
        // The fifth is over the urgent cap: it is not lost, it takes the open slot like any normal nudge...
        #expect(tick(&state, [cand("u4", urgent: true)], vn(14, 40)) == ["u4"])
        #expect(state.urgentToday == 4 && state.sentToday == 1 && state.slotsUsed == [13])
        // ...and the sixth has to wait for the next slot.
        #expect(tick(&state, [cand("u5", urgent: true)], vn(14, 50)) == [])
        #expect(tick(&state, [cand("u5", urgent: true)], vn(18, 59)) == [])
        #expect(tick(&state, [cand("u5", urgent: true)], vn(19, 0)) == ["u5"])
        // The next day the cap starts again.
        #expect(tick(&state, [cand("v", urgent: true)], vn(8, 0, day: 21)) == ["v"] && state.urgentToday == 1)
    }

    @Test func anUrgentCandidateWaitsOutQuietHoursAndShowsWhenTheyEnd() {
        var state = NudgeState()
        let u = cand("u", urgent: true, due: at(2026, 10, 21, 3))
        #expect(tick(&state, [u], vn(22, 0)) == [] && tick(&state, [u], vn(23, 59)) == [] && tick(&state, [u], vn(7, 59, day: 21)) == [])
        #expect(tick(&state, [u], vn(8, 0, day: 21)) == ["u"])
    }

    // MARK: held, off, ledger snooze

    @Test func nothingShowsWhileHeldAndTheSlotIsNotSpent() {
        var state = NudgeState()
        let pool = [cand("n"), cand("u", urgent: true)]
        #expect(tick(&state, pool, vn(9, 0), held: true) == [] && tick(&state, pool, vn(11, 0), held: true) == [])
        #expect(state.sentToday == 0 && state.urgentToday == 0 && state.slotsUsed.isEmpty)
        #expect(tick(&state, pool, vn(11, 5)) == ["u"])  // as soon as it lets go; slot 09:00 is still open for the other
        #expect(tick(&state, pool, vn(11, 6)) == ["n"])
    }

    @Test func nothingShowsWhileNudgesAreOff() {
        var state = NudgeState()
        state.enabled = false
        for h in [9, 11, 13, 19] { #expect(tick(&state, [cand("n"), cand("u", urgent: true)], vn(h, 0)) == []) }
        state.enabled = true
        #expect(tick(&state, [cand("n")], vn(19, 5)) == ["n"])
    }

    @Test func theLedgersSnoozeHoldsUntilItsDate() {
        var state = NudgeState()
        let until = vn(15, 0)
        #expect(tick(&state, [cand("n"), cand("u", urgent: true)], vn(9, 0), snooze: until) == [])
        #expect(tick(&state, [cand("u", urgent: true)], vn(14, 59), snooze: until) == [])
        #expect(tick(&state, [cand("u", urgent: true)], vn(15, 0), snooze: until) == ["u"])  // the date itself is over
        #expect(tick(&state, [cand("n")], vn(15, 1), snooze: vn(8, 0)) == ["n"])  // a snooze in the past does nothing (slot 13:00)
        #expect(tick(&state, [cand("m")], vn(9, 0, day: 21), snooze: nil) == ["m"])
    }

    // MARK: digest and contest

    @Test func oneDigestADay() {
        var state = NudgeState()
        #expect(tick(&state, [digest("g1"), digest("g2")], vn(9, 0)) == ["g1"])
        #expect(tick(&state, [digest("g2")], vn(13, 0)) == [])  // the slot is free, the day's digest is gone
        #expect(tick(&state, [digest("g2")], vn(19, 0)) == [])
        #expect(tick(&state, [digest("g2")], vn(9, 0, day: 21)) == ["g2"])
    }

    @Test func aDigestIsNotCountedAgainstOtherNudgesOfTheSlot() {
        var state = NudgeState()
        #expect(tick(&state, [digest("g")], vn(9, 0)) == ["g"])
        #expect(tick(&state, [cand("d")], vn(13, 0)) == ["d"])
    }

    @Test func afterThreeDismissedDigestsInARowTheDigestComesEveryOtherDay() {
        var state = NudgeState()
        var shownOn: [Int] = []
        for day in 20...30 {
            let got = show(&state, [digest("g\(day)")], vn(9, 0, day: day))
            if !got.isEmpty {
                shownOn.append(day)
                answer(&state, got, .dismissed, vn(9, 1, day: day))
            }
        }
        // Daily until the third dismissal (22nd), then every other day: 24th, 26th, 28th, 30th.
        #expect(shownOn == [20, 21, 22, 24, 26, 28, 30])
    }

    @Test func openingADigestStartsTheDailyRhythmAgain() {
        var state = NudgeState()
        for day in 20...22 { answer(&state, show(&state, [digest("g\(day)")], vn(9, 0, day: day)), .dismissed, vn(9, 1, day: day)) }
        #expect(state.dismissedDigestStreak == 3)
        #expect(tick(&state, [digest("g23")], vn(9, 0, day: 23)) == [])
        let got = show(&state, [digest("g24")], vn(9, 0, day: 24))
        #expect(got.map(\.id) == ["g24"])
        answer(&state, got, .opened, vn(9, 2, day: 24))
        #expect(state.dismissedDigestStreak == 0)
        #expect(tick(&state, [digest("g25")], vn(9, 0, day: 25)) == ["g25"])  // daily again
    }

    @Test func onlyDismissedDigestsCountAndOpeningAnotherCardDoesNotEndTheRun() {
        var state = NudgeState()
        let d = show(&state, [cand("d")], vn(9, 0))
        answer(&state, d, .dismissed, vn(9, 1))
        #expect(state.dismissedDigestStreak == 0)
        state.dismissedDigestStreak = 2
        let again = show(&state, [cand("d2")], vn(13, 0))
        answer(&state, again, .opened, vn(13, 1))
        #expect(state.dismissedDigestStreak == 2)
        let g = show(&state, [digest("g")], vn(19, 0))
        answer(&state, g, .later, vn(19, 1))
        #expect(state.dismissedDigestStreak == 2)
    }

    @Test func oneContestADayAndThreeAWeek() {
        var state = NudgeState()
        var shownOn: [Int] = []
        for day in 19...26 {
            if !tick(&state, [contest("c\(day)"), contest("x\(day)")], vn(9, 0, day: day)).isEmpty { shownOn.append(day) }
        }
        // Monday to Wednesday of ISO week 43; Thursday to Sunday are over the cap; Monday 10-26 is week 44.
        #expect(shownOn == [19, 20, 21, 26])
        #expect(state.contestWeek == "2026-W44" && state.contestThisWeek == 1)
    }

    @Test func aSecondContestTheSameDayWaitsEvenWithSlotsFree() {
        var state = NudgeState()
        #expect(tick(&state, [contest("c1"), contest("c2")], vn(9, 0)) == ["c1"])
        #expect(tick(&state, [contest("c2")], vn(13, 0)) == [])
    }

    @Test func theWeekIsTheISOWeekInTheUsersZoneNotUTCs() {
        var state = NudgeState()
        state.contestThisWeek = 3
        state.contestWeek = "2026-W43"
        // Sunday 2026-10-25 20:00Z is Monday 03:00 in Vietnam: already week 44 there, still week 43 in UTC.
        tick(&state, [], at(2026, 10, 25, 20), zone: VN)
        #expect(state.contestWeek == "2026-W44" && state.contestThisWeek == 0)
        var utc = NudgeState()
        utc.contestThisWeek = 3
        utc.contestWeek = "2026-W43"
        tick(&utc, [], at(2026, 10, 25, 20), zone: UTC)
        #expect(utc.contestWeek == "2026-W43" && utc.contestThisWeek == 3)
    }

    @Test func theISOWeekAtTheEndOfTheYearBelongsToTheNextYear() {
        var state = NudgeState()
        tick(&state, [], at(2026, 12, 31, 12, 0, VN))  // Thursday: ISO week 53 of 2026
        #expect(state.contestWeek == "2026-W53")
        tick(&state, [], at(2027, 1, 1, 12, 0, VN))  // Friday: still week 53
        #expect(state.contestWeek == "2026-W53")
        tick(&state, [], at(2027, 1, 4, 12, 0, VN))  // Monday: week 1 of 2027
        #expect(state.contestWeek == "2027-W01")
    }

    // MARK: opportunities

    /// (hours until it is due, saved, urgent, shown).
    @Test(arguments: [
        (nil, false, false, false), (200.0, false, false, false), (72.01, false, false, false), (72.0, false, false, true), (24.0, false, false, true),
        (0.5, false, false, true), (0.0, false, false, false), (-3.0, false, false, false), (nil, true, false, true), (500.0, true, false, true),
        (-3.0, true, false, false), (0.0, true, false, false), (nil, false, true, true), (500.0, false, true, true), (-1.0, false, true, false),
    ] as [(Double?, Bool, Bool, Bool)])
    func anOpportunityNudgesOnlyWhenSavedUrgentOrDueWithin72Hours(hours: Double?, saved: Bool, urgent: Bool, shows: Bool) {
        var state = NudgeState()
        let now = vn(9, 0)
        let o = cand("o", .opportunity, urgent: urgent, due: hours.map { now.addingTimeInterval($0 * 3600) }, saved: saved)
        #expect(tick(&state, [o], now) == (shows ? ["o"] : []), "due in \(String(describing: hours)) h, saved \(saved), urgent \(urgent)")
    }

    // MARK: Later, Not for me

    @Test func laterBringsTheCandidateBackAtTheNextSlot() {
        var state = NudgeState()
        let got = show(&state, [cand("d")], vn(9, 0))
        answer(&state, got, .later, vn(9, 5))
        #expect(state.snoozedUntil["d"] == vn(13, 0))
        #expect(tick(&state, [cand("d")], vn(12, 59)) == [])
        #expect(tick(&state, [cand("d")], vn(13, 0)) == ["d"])
    }

    /// (when Later is pressed, the slot it lasts until).
    @Test(arguments: [
        (vn(7, 0), vn(9, 0)), (vn(8, 59), vn(9, 0)), (vn(9, 0), vn(13, 0)), (vn(12, 59), vn(13, 0)), (vn(13, 0), vn(19, 0)), (vn(18, 59), vn(19, 0)),
        (vn(19, 0), vn(9, 0, day: 21)), (vn(19, 30), vn(9, 0, day: 21)), (vn(23, 59), vn(9, 0, day: 21)),
    ] as [(Date, Date)])
    func laterLastsUntilTheNextSlotStart(pressed: Date, until: Date) {
        var state = NudgeState()
        answer(&state, [cand("d")], .later, pressed)
        #expect(state.snoozedUntil["d"] == until)
    }

    @Test func laterOnAnUrgentCardBringsItBackAtOnceWhenTheSlotComes() {
        var state = NudgeState()
        let u = cand("u", urgent: true, due: vn(15, 0))
        let got = show(&state, [u], vn(11, 0))
        answer(&state, got, .later, vn(11, 1))
        #expect(tick(&state, [u], vn(12, 59)) == [])
        #expect(tick(&state, [u], vn(13, 0)) == ["u"])
        #expect(state.urgentToday == 2)
    }

    /// (what is due, when Later is pressed, when it returns): never past the thing, never sooner than 5 minutes.
    @Test(arguments: [
        (vn(10, 42), vn(10, 20), vn(10, 27)),  // a meeting in 22 min: 15 min before it, not the 13:00 slot
        (vn(12, 30), vn(10, 20), vn(12, 15)),  // a deadline at 12:30 under the 13:00 slot
        (vn(10, 30), vn(10, 20), vn(10, 25)),  // 10 min away: the 5-minute floor
        (vn(10, 22), vn(10, 20), vn(10, 25)),  // due before the floor: it will be past by then and never shows
        (vn(15, 0), vn(11, 1), vn(13, 0)),  // a slot comes first: the slot
        (vn(9, 0, day: 21), vn(10, 20), vn(13, 0)),  // tomorrow morning: the slot
    ] as [(Date, Date, Date)])
    func laterNeverLastsPastTheThingItself(due: Date, pressed: Date, returns: Date) {
        var state = NudgeState()
        answer(&state, [cand("m", urgent: true, due: due)], .later, pressed)
        #expect(state.snoozedUntil["m"] == returns)
    }

    @Test func aSnoozeEndsAndIsForgotten() {
        var state = NudgeState()
        answer(&state, [cand("d")], .later, vn(9, 0))
        #expect(state.snoozedUntil.count == 1)
        tick(&state, [], vn(13, 0))
        #expect(state.snoozedUntil.isEmpty)
    }

    @Test func notForMeKeepsTheCandidateAwayForThirtyDays() {
        var state = NudgeState()
        let got = show(&state, [cand("d")], vn(9, 0))
        answer(&state, got, .notForMe, vn(9, 1))
        for day in [20, 21, 25, 30] { #expect(tick(&state, [cand("d")], vn(9, 0, day: day)) == []) }
        #expect(tick(&state, [cand("d")], at(2026, 11, 18, 13, 0, VN)) == [])  // 29 days on
        #expect(tick(&state, [cand("d")], at(2026, 11, 19, 9, 1, VN)) == ["d"])  // 30 days after the answer, then it may come back
        #expect(tick(&state, [cand("e")], at(2026, 11, 19, 13, 0, VN)) == ["e"])  // others were never affected
    }

    @Test func threeNotForMeInARowMuteTheCategoryUntilItIsTurnedOnAgain() {
        var state = NudgeState()
        for i in 1...3 {
            let got = show(&state, [digest("g\(i)")], vn(9, 0, day: 20 + i))
            #expect(got.map(\.id) == ["g\(i)"], "g\(i) is shown")
            answer(&state, got, .notForMe, vn(9, 1, day: 20 + i))
        }
        #expect(state.mutedCategories == [.digest])
        for day in 24...30 { #expect(tick(&state, [digest("again\(day)")], vn(9, 0, day: day)) == [], "day \(day)") }
        #expect(tick(&state, [cand("ud", .digest, urgent: true, due: nil)], vn(9, 0, day: 30)) == [])
        #expect(tick(&state, [cand("d")], vn(9, 0, day: 30)) == ["d"])  // the other categories are fine
        state.unmute(.digest)
        #expect(state.mutedCategories.isEmpty && state.notForMeStreak["digest"] == 0)
        #expect(tick(&state, [digest("back")], vn(9, 0, day: 31)) == ["back"])
    }

    @Test func anOpenedCardEndsTheRunOfNotForMeAnswers() {
        var state = NudgeState()
        func round(_ day: Int, _ outcome: NudgeBudget.Outcome) {
            answer(&state, show(&state, [cand("o\(day)", .opportunity, due: nil, saved: true)], vn(9, 0, day: day)), outcome, vn(9, 1, day: day))
        }
        round(20, .notForMe); round(21, .notForMe)
        #expect(state.notForMeStreak["opportunity"] == 2 && state.mutedCategories.isEmpty)
        round(22, .opened)
        #expect(state.notForMeStreak["opportunity"] == 0)
        round(23, .notForMe); round(24, .notForMe)
        #expect(state.mutedCategories.isEmpty)
        round(25, .notForMe)
        #expect(state.mutedCategories == [.opportunity])
    }

    @Test func laterAndDismissedDoNotBreakTheRunOfNotForMe() {
        var state = NudgeState()
        let ids = ["a", "b", "c", "d", "e"]
        let outcomes: [NudgeBudget.Outcome] = [.notForMe, .later, .notForMe, .dismissed, .notForMe]
        for (i, outcome) in outcomes.enumerated() {
            let got = show(&state, [cand(ids[i], .opportunity, due: nil, saved: true)], vn(9, 0, day: 19 + i))
            #expect(got.count == 1, "\(ids[i]) is shown")
            answer(&state, got, outcome, vn(9, 1, day: 19 + i))
        }
        #expect(state.notForMeStreak["opportunity"] == 3 && state.mutedCategories == [.opportunity])
    }

    @Test func aMergedCardAnsweredNotForMeCountsOnceForItsCategoryButMutesEveryItem() {
        var state = NudgeState()
        let pool = [cand("d1", due: at(2026, 10, 24)), cand("d2", due: at(2026, 10, 25)), cand("d3", due: at(2026, 10, 26))]
        let got = show(&state, pool, vn(9, 0))
        #expect(got.count == 3)
        answer(&state, got, .notForMe, vn(9, 1))
        #expect(state.notForMeStreak["deadline"] == 1 && state.mutedCategories.isEmpty)
        #expect(Set(state.mutedUntil.keys) == ["d1", "d2", "d3"])
        #expect(tick(&state, pool, vn(13, 0)) == [])
    }

    @Test func eachCategoryKeepsItsOwnRun() {
        var state = NudgeState()
        for (i, category) in [NudgeCategory.digest, .contest, .digest, .contest, .digest].enumerated() {
            let c = cand("x\(i)", category, due: nil)
            answer(&state, [c], .notForMe, vn(9, 0, day: 20 + i))
        }
        #expect(state.notForMeStreak["digest"] == 3 && state.notForMeStreak["contest"] == 2)
        #expect(state.mutedCategories == [.digest])
    }

    @Test func aMutedCategoryIsNeverShownEvenUrgent() {
        var state = NudgeState()
        state.mutedCategories = [.deadline]
        #expect(tick(&state, [cand("u", urgent: true), cand("n")], vn(9, 0)) == [])
        #expect(tick(&state, [cand("e", .event)], vn(9, 0)) == ["e"])
    }

    // MARK: DST and zones other than the machine's

    @Test func theSameInstantIsAnotherLocalTimeInEveryZone() {
        // 02:00Z: 09:00 in Vietnam (slot opens), 04:00 in Berlin (quiet), 22:00 the evening before in New York (quiet).
        let now = at(2026, 10, 20, 2)
        for (zone, shows) in [(VN, true), (BERLIN, false), (NEW_YORK, false), (UTC, false)] {
            var state = NudgeState()
            #expect(tick(&state, [cand("d")], now, zone: zone) == (shows ? ["d"] : []), "\(zone.identifier)")
        }
        // 12:00Z: 19:00 in Vietnam, 14:00 in Berlin (the 13:00 slot is open), 08:00 in New York (no slot yet, but urgent is allowed).
        let noon = at(2026, 10, 20, 12)
        var vnState = NudgeState(), berlin = NudgeState(), newYork = NudgeState()
        #expect(tick(&vnState, [cand("d")], noon, zone: VN) == ["d"] && vnState.slotsUsed == [19])
        #expect(tick(&berlin, [cand("d")], noon, zone: BERLIN) == ["d"] && berlin.slotsUsed == [13])
        #expect(tick(&newYork, [cand("d")], noon, zone: NEW_YORK) == [])
        #expect(tick(&newYork, [cand("u", urgent: true)], noon, zone: NEW_YORK) == ["u"])
        #expect(vnState.day == "2026-10-20" && berlin.day == "2026-10-20" && newYork.day == "2026-10-20")
    }

    @Test func theDayKeyIsTheLocalDateOfTheZone() {
        // 23:30Z on the 20th.
        for (zone, day) in [(UTC, "2026-10-20"), (VN, "2026-10-21"), (BERLIN, "2026-10-21"), (NEW_YORK, "2026-10-20")] {
            var s = NudgeState()
            tick(&s, [], at(2026, 10, 20, 23, 30), zone: zone)
            #expect(s.day == day, "\(zone.identifier)")
        }
    }

    @Test func theDayOfTheClockChangeBackHasItsThreeSlotsAtTheLocalHours() {
        // Berlin, Sunday 2026-10-25: 25 hours long. The slots are 09:00, 13:00 and 19:00 CET (08:00Z, 12:00Z, 18:00Z).
        var state = NudgeState()
        tick(&state, [], at(2026, 10, 24, 19, 0, BERLIN), zone: BERLIN)  // Saturday evening: summer time
        #expect(state.day == "2026-10-24")
        #expect(tick(&state, [cand("n0")], at(2026, 10, 25, 8, 59, BERLIN), zone: BERLIN) == [] && state.day == "2026-10-25")
        #expect(tick(&state, [cand("n0")], at(2026, 10, 25, 8, 59, BERLIN), zone: BERLIN) == [])
        #expect(tick(&state, [cand("n0")], at(2026, 10, 25, 9, 0, BERLIN), zone: BERLIN) == ["n0"])
        #expect(at(2026, 10, 25, 9, 0, BERLIN) == at(2026, 10, 25, 8))  // 09:00 CET
        #expect(tick(&state, [cand("n1")], at(2026, 10, 25, 13, 0, BERLIN), zone: BERLIN) == ["n1"])
        #expect(tick(&state, [cand("n2")], at(2026, 10, 25, 19, 0, BERLIN), zone: BERLIN) == ["n2"])
        #expect(tick(&state, [cand("n3")], at(2026, 10, 25, 21, 59, BERLIN), zone: BERLIN) == [])
        #expect(state.sentToday == 3)
    }

    @Test func theHourThatRepeatsOnTheClockChangeDayIsQuietBothTimes() {
        var state = NudgeState()
        // 00:30Z and 01:30Z are both "02:30" in Berlin that night.
        for now in [at(2026, 10, 25, 0, 30), at(2026, 10, 25, 1, 30), at(2026, 10, 25, 2, 30)] {
            #expect(tick(&state, [cand("n"), cand("u", urgent: true)], now, zone: BERLIN) == [])
        }
        // 08:00 CET is 07:00Z: urgent nudges are allowed from then, not a minute before.
        #expect(tick(&state, [cand("u", urgent: true)], at(2026, 10, 25, 6, 59), zone: BERLIN) == [])
        #expect(tick(&state, [cand("u", urgent: true)], at(2026, 10, 25, 7, 0), zone: BERLIN) == ["u"])
    }

    @Test func laterAcrossTheClockChangeLastsUntilNineLocalNotNineHoursAndAHalfOn() {
        var state = NudgeState()
        let pressed = at(2026, 10, 24, 19, 30, BERLIN)  // Saturday 17:30Z
        answer(&state, [cand("d")], .later, pressed, zone: BERLIN)
        #expect(state.snoozedUntil["d"] == at(2026, 10, 25, 9, 0, BERLIN))
        #expect(state.snoozedUntil["d"] == at(2026, 10, 25, 8))
        #expect(state.snoozedUntil["d"]!.timeIntervalSince(pressed) == 14.5 * 3600)  // 13.5 clock hours, and the repeated hour
    }

    @Test func theSpringForwardDayKeepsItsSlotsToo() {
        // New York, Sunday 2026-03-08: 23 hours long, 09:00 EDT is 13:00Z.
        var state = NudgeState()
        #expect(tick(&state, [cand("a")], at(2026, 3, 8, 12, 59), zone: NEW_YORK) == [])
        #expect(tick(&state, [cand("a")], at(2026, 3, 8, 13, 0), zone: NEW_YORK) == ["a"])
        #expect(tick(&state, [cand("b")], at(2026, 3, 8, 9, 30, NEW_YORK), zone: NEW_YORK) == [])  // the 09:00 slot is used
        #expect(tick(&state, [cand("b")], at(2026, 3, 8, 12, 59, NEW_YORK), zone: NEW_YORK) == [])
        #expect(tick(&state, [cand("b")], at(2026, 3, 8, 13, 0, NEW_YORK), zone: NEW_YORK) == ["b"])  // 17:00Z
        var later = NudgeState()
        answer(&later, [cand("x")], .later, at(2026, 3, 7, 20, 0, NEW_YORK), zone: NEW_YORK)  // Saturday evening, winter time
        #expect(later.snoozedUntil["x"] == at(2026, 3, 8, 9, 0, NEW_YORK))
        #expect(later.snoozedUntil["x"] == at(2026, 3, 8, 13))
    }

    // MARK: a whole simulated day

    @Test func aDayInTheLifeOfTheBudget() {
        var state = NudgeState()
        var log: [String] = []
        func t(_ h: Int, _ m: Int, _ cs: [NudgeCandidate], day: Int = 20, held: Bool = false) {
            let got = tick(&state, cs, vn(h, m, day: day), held: held)
            if !got.isEmpty { log.append(String(format: "%02d:%02d %@", h, m, got.joined(separator: "+"))) }
        }
        let d1 = cand("d1", due: at(2026, 10, 22)), d2 = cand("d2", due: at(2026, 10, 23)), u1 = cand("u1", urgent: true, due: vn(14, 0))
        let g = digest("g"), c = contest("c"), u2 = cand("u2", .event, urgent: true, due: vn(0, 30, day: 21))

        t(8, 30, [d1])  // before the first slot
        t(9, 0, [d1])  // slot 1
        t(9, 30, [d1, d2])  // slot 1 is used
        t(10, 0, [d2], held: true)  // the card is up: nothing, and nothing spent
        t(11, 0, [d2, u1])  // urgent now
        t(11, 30, [d2, u1])  // already shown
        t(13, 0, [d2, g])  // slot 2: the deadline
        t(14, 0, [g, c])  // slot 2 used
        t(19, 0, [g, c])  // slot 3: the digest (before the contest)
        t(20, 0, [c])  // three normal nudges done
        t(22, 0, [u2])  // quiet hours
        t(8, 0, [u2], day: 21)  // the urgent one shows when they end... (its time has passed by then: stays hidden)
        t(9, 0, [c], day: 21)  // a new day: the contest
        #expect(log == ["09:00 d1", "11:00 u1", "13:00 d2", "19:00 g", "09:00 c"])
    }

    // MARK: the state file

    @Test func theStateRoundTripsThroughJSON() {
        var state = NudgeState()
        let shown = show(&state, [cand("d1"), contest("c1")], vn(9, 0))
        answer(&state, shown, .notForMe, vn(9, 1))
        answer(&state, [cand("x")], .later, vn(10, 0))
        state.mutedCategories = [.digest, .opportunity]
        state.dismissedDigestStreak = 2
        state.lastDigestDay = "2026-10-19"
        state.enabled = false
        let data = NudgeBudget.encode(state)
        #expect(NudgeBudget.decode(data) == state)
        #expect(NudgeBudget.encode(NudgeBudget.decode(data)) == data)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"day\" : \"2026-10-20\"") && text.contains("\"snoozedUntil\""))
        #expect(text.contains("\"d1\" : \"2026-11-19T02:01:00Z\""))  // "Not for me" at 09:01 Vietnam time, 30 days on, in UTC
        #expect(text.contains("\"digest\"") && text.contains("\"opportunity\""))
        #expect(text.range(of: "\"digest\"")!.lowerBound < text.range(of: "\"opportunity\"")!.lowerBound)  // muted categories in a fixed order
    }

    @Test func aMissingFieldIsItsDefaultAndAGarbageFileIsAFreshState() {
        #expect(NudgeBudget.decode(Data("{}".utf8)) == NudgeState())
        #expect(NudgeBudget.decode(Data("{\"sentToday\": 2, \"mutedCategories\": [\"digest\"], \"future\": 1}".utf8)).sentToday == 2)
        #expect(NudgeBudget.decode(Data("{\"sentToday\": 2, \"mutedCategories\": [\"digest\"]}".utf8)).mutedCategories == [.digest])
        #expect(NudgeBudget.decode(Data("{\"sentToday\": 2}".utf8)).enabled)
        for junk in ["", "not json", "[]", "null", "{\"sentToday\": \"many\"}", "{\"mutedCategories\": [\"nonsense\"]}"] {
            #expect(NudgeBudget.decode(Data(junk.utf8)) == NudgeState(), "\(junk)")
        }
    }

    @Test func aStateFromAnotherDayIsStartedAgainWithoutLosingTheLongTermFields() {
        var state = NudgeState()
        state.day = "2026-10-10"
        state.sentToday = 3
        state.urgentToday = 4
        state.slotsUsed = [9, 13, 19]
        state.sentByCategory = ["digest": 1]
        state.mutedCategories = [.contest]
        state.dismissedDigestStreak = 2
        state.lastDigestDay = "2026-10-10"
        tick(&state, [], vn(9, 0))
        #expect(state.day == "2026-10-20" && state.sentToday == 0 && state.urgentToday == 0 && state.slotsUsed.isEmpty && state.sentByCategory.isEmpty)
        #expect(state.mutedCategories == [.contest] && state.dismissedDigestStreak == 2 && state.lastDigestDay == "2026-10-10")
    }

    @Test func theShownMemoryIsKeptSixtyDays() {
        var state = NudgeState()
        #expect(tick(&state, [cand("d")], vn(9, 0)) == ["d"])
        #expect(tick(&state, [cand("d")], at(2026, 12, 18, 9, 0, VN)) == [])  // 59 days on
        #expect(tick(&state, [cand("d")], at(2026, 12, 20, 9, 0, VN)) == ["d"])  // 61 days on: forgotten
    }
}
