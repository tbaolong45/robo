// The reminder ladder: which rung of an agenda item is due, one reminder at a time, the tightest rung standing for the looser
// ones after a sleep, dedupe by key, items that move, "new in your calendar", and calendar-day rungs across DST changes.
import Foundation
import Testing
@testable import RoboCore

private let UTC = TimeZone(identifier: "UTC")!
private let VN = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
private let BERLIN = TimeZone(identifier: "Europe/Berlin")!  // DST ends Sunday 2026-10-25 at 03:00 local
private let NEW_YORK = TimeZone(identifier: "America/New_York")!  // DST starts Sunday 2026-03-08 at 02:00 local

private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ zone: TimeZone = UTC) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

/// Friday 2026-10-23, 16:00Z: an assignment is due.
private let T = at(2026, 10, 23, 16)
private let LONG_AGO = at(2026, 9, 1)

/// An item seen long ago and never moved, so the "new" rung does not apply unless a test says so.
private func item(_ kind: AgendaItem.Kind, _ when: Date = T, id: String = "x", source: AgendaItem.Source = .ics, recurring: Bool = false,
                  firstSeen: Date = LONG_AGO, changed: Bool = false) -> AgendaItem {
    AgendaItem(id: id, title: "Item \(id)", kind: kind, when: when, source: source, recurring: recurring, firstSeen: firstSeen, changed: changed)
}

private func keys(_ item: AgendaItem, _ rungs: [Reminder.Rung]) -> Set<String> { Set(rungs.map { Reminders.key(item, $0) }) }

private func due(_ items: [AgendaItem], fired: Set<String> = [], now: Date, zone: TimeZone = UTC) -> [Reminder] {
    Reminders.due(items: items, fired: fired, now: now, zone: zone)
}

/// Ticks every `step` seconds from `from` to `to`; each reminder is recorded and its `covered` keys are fired, as the app does.
private func replay(_ items: [AgendaItem], from: Date, to: Date, step: TimeInterval = 600, zone: TimeZone = UTC, fired start: Set<String> = [],
                    skipping gap: ClosedRange<Date>? = nil) -> [(at: Date, id: String, rung: Reminder.Rung)] {
    var fired = start
    var out: [(at: Date, id: String, rung: Reminder.Rung)] = []
    var t = from
    while t <= to {
        if gap?.contains(t) != true {
            for r in Reminders.due(items: items, fired: fired, now: t, zone: zone) {
                fired.formUnion(r.covered)
                out.append((t, r.item.id, r.rung))
            }
        }
        t = t.addingTimeInterval(step)
    }
    return out
}

@Suite struct RemindersTests {
    // MARK: the ladders

    /// (seconds before the due time, rungs already fired, the rung that is due).
    @Test(arguments: [
        (90_000, [], nil), (86_401, [], nil), (86_400, [], .day), (50_000, [], .day), (50_000, [.day], nil), (10_801, [.day], nil),
        (10_800, [.day], .hours3), (10_800, [], .hours3), (60, [], .hours3), (60, [.day, .hours3], nil), (1, [.hours3], nil), (0, [], nil), (-60, [], nil),
    ] as [(Int, [Reminder.Rung], Reminder.Rung?)])
    func aDeadlineIsRemindedADayAndThreeHoursBefore(before: Int, fired: [Reminder.Rung], want: Reminder.Rung?) {
        let i = item(.deadline)
        let r = due([i], fired: keys(i, fired), now: T.addingTimeInterval(-Double(before)))
        #expect(r.map(\.rung) == (want.map { [$0] } ?? []), "T-\(before)s fired \(fired)")
    }

    @Test(arguments: [
        (8 * 86_400, [], nil), (7 * 86_400 + 1, [], nil), (7 * 86_400, [], .week), (3 * 86_400, [], .week), (3 * 86_400, [.week], nil),
        (86_401, [.week], nil), (86_400, [.week], .day), (86_400, [], .day), (10_801, [.week, .day], nil), (10_800, [.week, .day], .hours3),
        (10_800, [], .hours3), (10_800, [.hours3], nil), (0, [], nil),
    ] as [(Int, [Reminder.Rung], Reminder.Rung?)])
    func anExamIsRemindedAWeekADayAndThreeHoursBefore(before: Int, fired: [Reminder.Rung], want: Reminder.Rung?) {
        let i = item(.exam)
        let r = due([i], fired: keys(i, fired), now: T.addingTimeInterval(-Double(before)))
        #expect(r.map(\.rung) == (want.map { [$0] } ?? []), "T-\(before)s fired \(fired)")
    }

    @Test(arguments: [
        (7200, [], nil), (1801, [], nil), (1800, [], .meeting30), (600, [], .meeting30), (1, [], .meeting30), (1800, [.meeting30], nil), (0, [], nil), (-1, [], nil),
    ] as [(Int, [Reminder.Rung], Reminder.Rung?)])
    func aMeetingIsRemindedHalfAnHourBefore(before: Int, fired: [Reminder.Rung], want: Reminder.Rung?) {
        let i = item(.event)
        let r = due([i], fired: keys(i, fired), now: T.addingTimeInterval(-Double(before)))
        #expect(r.map(\.rung) == (want.map { [$0] } ?? []), "T-\(before)s fired \(fired)")
    }

    @Test(arguments: [
        (4 * 86_400, [], nil), (3 * 86_400 + 1, [], nil), (3 * 86_400, [], .days3), (2 * 86_400, [], .days3), (2 * 86_400, [.days3], nil),
        (86_400, [.days3], .day), (86_400, [], .day), (10_800, [.days3, .day], nil), (60, [.days3, .day], nil), (0, [], nil),
    ] as [(Int, [Reminder.Rung], Reminder.Rung?)])
    func anOpportunityIsRemindedThreeDaysAndADayBefore(before: Int, fired: [Reminder.Rung], want: Reminder.Rung?) {
        let i = item(.opportunity, source: .radar)
        let r = due([i], fired: keys(i, fired), now: T.addingTimeInterval(-Double(before)))
        #expect(r.map(\.rung) == (want.map { [$0] } ?? []), "T-\(before)s fired \(fired)")
    }

    @Test(arguments: [AgendaItem.Kind.deadline, .exam, .event, .opportunity])
    func aClassOfASeriesNeverRemindsAndNeitherDoesAnythingInThePast(_ kind: AgendaItem.Kind) {
        let series = item(kind, recurring: true)
        let past = item(kind, T.addingTimeInterval(-60))
        for lead in [Double(7 * 86_400), 86_400, 10_800, 1800, 60, 1] {
            #expect(due([series], now: T.addingTimeInterval(-lead)).isEmpty, "recurring \(kind) T-\(lead)")
        }
        #expect(due([past], now: T).isEmpty)
        #expect(due([item(kind)], now: T).isEmpty)  // exactly at the time is already past
    }

    @Test func aReminderCarriesTheItemTheRungTheKeyAndWhatItCovers() throws {
        let i = item(.deadline)
        let r = try #require(due([i], now: T.addingTimeInterval(-80_000)).first)  // 22 hours before
        #expect(r.item == i && r.rung == .day && r.key == Reminders.key(i, .day) && r.covered == [r.key])
        #expect(!r.urgent)
    }

    @Test func onlyTheLastHoursAndMinutesAreUrgent() throws {
        #expect(try #require(due([item(.deadline)], now: T.addingTimeInterval(-3600)).first).urgent)
        #expect(try #require(due([item(.exam)], now: T.addingTimeInterval(-3600)).first).urgent)
        #expect(try #require(due([item(.event)], now: T.addingTimeInterval(-600)).first).urgent)
        #expect(try #require(due([item(.exam)], now: T.addingTimeInterval(-3 * 86_400)).first).urgent == false)
        #expect(try #require(due([item(.exam)], now: T.addingTimeInterval(-86_400)).first).urgent == false)
        #expect(try #require(due([item(.opportunity)], now: T.addingTimeInterval(-86_400)).first).urgent == false)
        #expect(try #require(due([item(.opportunity)], now: T.addingTimeInterval(-3 * 86_400)).first).urgent == false)
    }

    @Test func theKeyHoldsTheIdTheRungAndTheTimeOfTheItem() {
        #expect(Reminders.key(item(.deadline, id: "48113@moodle.uni.example"), .hours3) == "48113@moodle.uni.example|hours3|\(Int(T.timeIntervalSince1970))")
        #expect(Reminders.key(item(.deadline), .day) != Reminders.key(item(.deadline), .hours3))
        #expect(Reminders.key(item(.deadline, id: "a"), .day) != Reminders.key(item(.deadline, id: "b"), .day))
        #expect(Reminders.key(item(.deadline), .day) != Reminders.key(item(.deadline, T.addingTimeInterval(60)), .day))
    }

    // MARK: several rungs due at once

    @Test func anItemFoundLateGetsOneReminderForTheTightestRungThatCoversTheLooserOnes() throws {
        let i = item(.deadline)
        let r = try #require(due([i], now: T.addingTimeInterval(-2 * 3600)).first)  // 2 h left: T-1d and T-3h have both passed
        #expect(r.rung == .hours3 && r.urgent)
        #expect(r.covered == [Reminders.key(i, .day), Reminders.key(i, .hours3)])
        #expect(due([i], fired: Set(r.covered), now: T.addingTimeInterval(-3600)).isEmpty)
        #expect(due([i], fired: [r.key], now: T.addingTimeInterval(-3600)).isEmpty)  // the tight rung alone is enough: no looser one comes after it
    }

    @Test func aLooserRungNeverFollowsATighterOneThatFired() {
        let i = item(.exam)
        for fired in [[Reminder.Rung.hours3], [.day], [.hours3, .week]] {
            #expect(due([i], fired: keys(i, fired), now: T.addingTimeInterval(-3600)).map(\.rung) == (fired.contains(.hours3) ? [] : [.hours3]), "\(fired)")
        }
    }

    @Test func anExamSeenWithTwoDaysLeftStartsAtTheWeekRungAndThenFollowsTheLadder() {
        let i = item(.exam)
        let seen = replay([i], from: T.addingTimeInterval(-2 * 86_400), to: T.addingTimeInterval(3600))
        #expect(seen.map(\.rung) == [.week, .day, .hours3])
        #expect(seen.map(\.at) == [T.addingTimeInterval(-2 * 86_400), T.addingTimeInterval(-86_400), T.addingTimeInterval(-10_800)])
    }

    @Test func aFullLadderFiresEachRungOnceAtItsTimeAndNothingElse() {
        let seen = replay([item(.exam)], from: T.addingTimeInterval(-9 * 86_400), to: T.addingTimeInterval(86_400))
        #expect(seen.map(\.rung) == [.week, .day, .hours3])
        #expect(seen.map(\.at) == [T.addingTimeInterval(-7 * 86_400), T.addingTimeInterval(-86_400), T.addingTimeInterval(-10_800)])
        let deadline = replay([item(.deadline)], from: T.addingTimeInterval(-3 * 86_400), to: T.addingTimeInterval(86_400))
        #expect(deadline.map(\.rung) == [.day, .hours3])
        let meeting = replay([item(.event)], from: T.addingTimeInterval(-86_400), to: T.addingTimeInterval(86_400))
        #expect(meeting.map(\.rung) == [.meeting30] && meeting.map(\.at) == [T.addingTimeInterval(-1800)])
        let opportunity = replay([item(.opportunity, source: .radar)], from: T.addingTimeInterval(-5 * 86_400), to: T.addingTimeInterval(86_400))
        #expect(opportunity.map(\.rung) == [.days3, .day])
    }

    @Test func aLongSleepGivesOneReminderOnWakingAndNothingStaleAfterIt() {
        // The laptop sleeps from three days before the exam to an hour before it: the week rung fired before, the day and
        // three-hour rungs passed in the dark. On waking: one reminder, the tightest, and the day rung never comes late.
        let i = item(.exam)
        let seen = replay([i], from: T.addingTimeInterval(-8 * 86_400), to: T.addingTimeInterval(86_400),
                          skipping: T.addingTimeInterval(-3 * 86_400 + 600)...T.addingTimeInterval(-3600 - 600))
        #expect(seen.map(\.rung) == [.week, .hours3])
        #expect(seen.map(\.at) == [T.addingTimeInterval(-7 * 86_400), T.addingTimeInterval(-3600)])
    }

    @Test func aSleepPastTheDueTimeGivesNothingAtAll() {
        let seen = replay([item(.exam), item(.deadline, id: "d"), item(.event, id: "e")], from: T.addingTimeInterval(-8 * 86_400), to: T.addingTimeInterval(86_400),
                          skipping: T.addingTimeInterval(-2 * 86_400)...T.addingTimeInterval(600))
        #expect(!seen.contains { $0.at > T.addingTimeInterval(-2 * 86_400) })
    }

    @Test func eachItemHasItsOwnReminderAndTheSoonestComesFirst() {
        let late = item(.deadline, T.addingTimeInterval(7200), id: "late"), soon = item(.deadline, T.addingTimeInterval(3600), id: "soon")
        let tie1 = item(.deadline, T.addingTimeInterval(3600), id: "b"), tie2 = item(.deadline, T.addingTimeInterval(3600), id: "a")
        let r = due([late, tie1, soon, tie2], now: T)
        #expect(r.map(\.item.id) == ["a", "b", "soon", "late"])  // by time, then id
        #expect(r.allSatisfy { $0.rung == .hours3 })
    }

    @Test func nothingIsDueForNothing() {
        #expect(due([], now: T).isEmpty)
    }

    // MARK: an item that moves

    @Test func aDeadlineExtendedAfterItsRemindersFiredIsRemindedAgainForTheNewTime() {
        let before = item(.deadline)
        let fired = keys(before, [.day, .hours3])
        let after = item(.deadline, T.addingTimeInterval(2 * 86_400), changed: true)
        #expect(due([before], fired: fired, now: T.addingTimeInterval(-60)).isEmpty)
        let seen = replay([after], from: T, to: T.addingTimeInterval(3 * 86_400), fired: fired)
        // A moved item is announced at once ("changed"), then the ladder runs again for the new time.
        #expect(seen.map(\.rung) == [.newEvent, .day, .hours3])
        #expect(seen.map(\.at) == [T, T.addingTimeInterval(86_400), T.addingTimeInterval(2 * 86_400 - 10_800)])
    }

    // MARK: new or moved in the calendar

    @Test func aNewCalendarEventIsAnnouncedOnceWhenItStartsWithinAWeek() throws {
        let now = at(2026, 10, 20, 2)
        let i = item(.event, now.addingTimeInterval(3 * 86_400), firstSeen: now)
        let r = try #require(due([i], now: now).first)
        #expect(r.rung == .newEvent && !r.urgent && r.covered == [r.key] && r.key == Reminders.key(i, .newEvent))
        #expect(due([i], fired: [r.key], now: now.addingTimeInterval(3600)).isEmpty)
    }

    @Test func aMovedEventIsAnnouncedAgainEvenIfItWasSeenLongAgo() throws {
        let now = at(2026, 10, 20, 2)
        let first = item(.event, now.addingTimeInterval(3 * 86_400), firstSeen: LONG_AGO)
        #expect(due([first], now: now).isEmpty)  // old and unchanged: not new
        let moved = item(.event, now.addingTimeInterval(4 * 86_400), firstSeen: LONG_AGO, changed: true)
        let r = try #require(due([moved], fired: keys(first, [.newEvent]), now: now).first)
        #expect(r.rung == .newEvent)
        let movedAgain = item(.event, now.addingTimeInterval(5 * 86_400), firstSeen: LONG_AGO, changed: true)
        #expect(due([movedAgain], fired: Set(r.covered), now: now).map(\.rung) == [.newEvent])
        #expect(due([moved], fired: Set(r.covered), now: now).isEmpty)
    }

    @Test func newIsOnlyForTheCalendarFeedAndOnlyForAWeekAheadAndOnlyForADay() {
        let now = at(2026, 10, 20, 2)
        func rungs(_ i: AgendaItem, at t: Date = now) -> [Reminder.Rung] { due([i], now: t).map(\.rung) }
        #expect(rungs(item(.event, now.addingTimeInterval(7 * 86_400), firstSeen: now)) == [.newEvent])
        #expect(rungs(item(.event, now.addingTimeInterval(7 * 86_400 + 1), firstSeen: now)).isEmpty)  // beyond a week
        #expect(rungs(item(.event, now.addingTimeInterval(86_400), source: .lms, firstSeen: now)).isEmpty)
        #expect(rungs(item(.event, now.addingTimeInterval(86_400), source: .ledger, firstSeen: now)).isEmpty)
        #expect(rungs(item(.event, now.addingTimeInterval(86_400), source: .radar, firstSeen: now)).isEmpty)
        #expect(rungs(item(.event, now.addingTimeInterval(86_400), recurring: true, firstSeen: now)).isEmpty)
        #expect(rungs(item(.event, now.addingTimeInterval(86_400), firstSeen: now.addingTimeInterval(-86_400))) == [.newEvent])  // a day old
        #expect(rungs(item(.event, now.addingTimeInterval(86_400), firstSeen: now.addingTimeInterval(-86_401))).isEmpty)
        #expect(rungs(item(.event, now.addingTimeInterval(-60), firstSeen: now)).isEmpty)  // already started
    }

    @Test func aNewDeadlineIsAnnouncedAndThenFollowsItsLadder() {
        let now = at(2026, 10, 20, 2)
        let i = item(.deadline, now.addingTimeInterval(5 * 86_400), firstSeen: now)
        let seen = replay([i], from: now, to: now.addingTimeInterval(6 * 86_400))
        #expect(seen.map(\.rung) == [.newEvent, .day, .hours3])
        #expect(seen[0].at == now)
    }

    @Test func aNewMeetingSoonerThanItsReminderIsOnlyTheReminder() throws {
        let now = at(2026, 10, 20, 2)
        let i = item(.event, now.addingTimeInterval(20 * 60), firstSeen: now)
        let r = try #require(due([i], now: now).first)
        #expect(r.rung == .meeting30 && r.urgent)
        #expect(r.covered == [Reminders.key(i, .newEvent), Reminders.key(i, .meeting30)])
        #expect(due([i], fired: Set(r.covered), now: now.addingTimeInterval(60)).isEmpty)
    }

    @Test func aNewDeadlineWithHoursLeftIsOneUrgentReminderCoveringTheAnnouncementAndTheDayRung() throws {
        let now = at(2026, 10, 20, 2)
        let i = item(.deadline, now.addingTimeInterval(2 * 3600), firstSeen: now)
        let r = try #require(due([i], now: now).first)
        #expect(r.rung == .hours3 && r.covered.count == 3)
    }

    @Test func seedingTheFirstImportKeepsTheWeeksEventsQuietButNotTheirReminders() {
        let now = at(2026, 10, 20, 2)
        let first = (1...5).map { item(.event, now.addingTimeInterval(Double($0) * 86_400), id: "e\($0)", firstSeen: now) }
        #expect(due(first, now: now).count == 5)  // a flood if nothing is seeded
        let seeded = Set(first.map { Reminders.key($0, .newEvent) })
        #expect(due(first, fired: seeded, now: now).isEmpty)
        let seen = replay(first, from: now, to: now.addingTimeInterval(6 * 86_400), fired: seeded)
        #expect(seen.map(\.rung) == Array(repeating: .meeting30, count: 5))
    }

    // MARK: DST

    @Test func aDayBeforeIsTheSameWallClockEvenWhenTheDayHas25Hours() {
        // Sunday 2026-10-25 09:00 in Berlin is after the change back to winter time: 08:00Z. "A day before" is Saturday 09:00
        // local, still summer time: 07:00Z, 25 hours earlier.
        let exam = item(.exam, at(2026, 10, 25, 9, 0, BERLIN), source: .ledger)
        #expect(exam.when == at(2026, 10, 25, 8))
        #expect(due([exam], fired: keys(exam, [.week]), now: at(2026, 10, 24, 6, 59), zone: BERLIN).isEmpty)
        #expect(due([exam], fired: keys(exam, [.week]), now: at(2026, 10, 24, 7, 0), zone: BERLIN).map(\.rung) == [.day])
        // The same instants in a zone without DST: 24 hours exactly.
        #expect(due([exam], fired: keys(exam, [.week]), now: at(2026, 10, 24, 7, 0), zone: VN).isEmpty)
        #expect(due([exam], fired: keys(exam, [.week]), now: at(2026, 10, 24, 8, 0), zone: VN).map(\.rung) == [.day])
    }

    @Test func aWeekBeforeAcrossTheChangeIsStillTheSameWallClock() {
        let exam = item(.exam, at(2026, 10, 25, 9, 0, BERLIN), source: .ledger)
        #expect(due([exam], now: at(2026, 10, 18, 6, 59), zone: BERLIN).isEmpty)  // Sunday 10-18 09:00 CEST is 07:00Z
        #expect(due([exam], now: at(2026, 10, 18, 7, 0), zone: BERLIN).map(\.rung) == [.week])
    }

    @Test func aDayBeforeIsTheSameWallClockWhenTheDayHas23Hours() {
        // Sunday 2026-03-08 09:00 in New York is summer time: 13:00Z. Saturday 09:00 was winter time: 14:00Z, 23 hours earlier.
        let exam = item(.exam, at(2026, 3, 8, 9, 0, NEW_YORK), source: .ledger)
        #expect(exam.when == at(2026, 3, 8, 13))
        #expect(due([exam], fired: keys(exam, [.week]), now: at(2026, 3, 7, 13, 59), zone: NEW_YORK).isEmpty)
        #expect(due([exam], fired: keys(exam, [.week]), now: at(2026, 3, 7, 14, 0), zone: NEW_YORK).map(\.rung) == [.day])
    }

    @Test func hoursAndMinutesAreAbsoluteAcrossTheChange() {
        // 05:00 CET on 10-25 is 04:00Z; three hours before that is 01:00Z, the very moment Berlin falls back from 03:00 to 02:00.
        let exam = item(.exam, at(2026, 10, 25, 5, 0, BERLIN), source: .ledger)
        #expect(exam.when == at(2026, 10, 25, 4))
        let fired = keys(exam, [.week, .day])
        #expect(due([exam], fired: fired, now: at(2026, 10, 25, 0, 59), zone: BERLIN).isEmpty)
        #expect(due([exam], fired: fired, now: at(2026, 10, 25, 1, 0), zone: BERLIN).map(\.rung) == [.hours3])
        let meeting = item(.event, at(2026, 10, 25, 3, 30, BERLIN))  // 02:30 CEST or CET: ambiguous local time, one instant
        #expect(due([meeting], now: meeting.when.addingTimeInterval(-1801), zone: BERLIN).isEmpty)
        #expect(due([meeting], now: meeting.when.addingTimeInterval(-1800), zone: BERLIN).map(\.rung) == [.meeting30])
    }

    @Test func theWholeLadderOfAnExamOnTheChangeDayRunsInOrderInEveryZone() {
        for zone in [BERLIN, NEW_YORK, VN, UTC] {
            let exam = item(.exam, at(2026, 10, 25, 9, 0, zone), source: .ledger)
            let seen = replay([exam], from: exam.when.addingTimeInterval(-9 * 86_400), to: exam.when.addingTimeInterval(86_400), step: 300, zone: zone)
            #expect(seen.map(\.rung) == [.week, .day, .hours3], "\(zone.identifier)")
            #expect(seen.last?.at == exam.when.addingTimeInterval(-10_800))
        }
    }

    // MARK: the zone is the caller's

    @Test func theSameInstantIsDueInOneZoneAndNotInAnotherAroundTheChange() {
        let exam = item(.exam, at(2026, 10, 25, 8), source: .ledger)  // 08:00Z
        let fired = keys(exam, [.week])
        let now = at(2026, 10, 24, 7, 30)
        #expect(due([exam], fired: fired, now: now, zone: BERLIN).map(\.rung) == [.day])  // Berlin: Saturday 09:00 CEST was 07:00Z
        #expect(due([exam], fired: fired, now: now, zone: UTC).isEmpty)  // UTC: Saturday 08:00Z has not come
    }
}
