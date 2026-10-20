// The calendar feed parser: a Moodle-shaped feed (UTC), an Outlook-shaped one (Windows zone names, weekly RRULE with BYDAY and
// EXDATE, an all-day event, folded lines, CRLF, a moved single occurrence), the recurrence rules one by one, and hostile input.
// Nothing here depends on the machine's zone: every zone is named.
import Foundation
import Testing
@testable import RoboCore

private let UTC = TimeZone(identifier: "UTC")!
private let VN = TimeZone(identifier: "Asia/Ho_Chi_Minh")!  // the user's zone: no DST
private let BERLIN = TimeZone(identifier: "Europe/Berlin")!  // DST ends Sunday 2026-10-25
private let NEW_YORK = TimeZone(identifier: "America/New_York")!  // DST starts Sunday 2026-03-08

private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ zone: TimeZone = UTC) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

/// Tuesday 2026-10-20, 09:00 in Vietnam. The window is 2026-10-19 02:00Z to 2026-11-19 02:00Z.
private let NOW = at(2026, 10, 20, 9, 0, VN)

private func crlf(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "\r\n") }

/// A VEVENT with a UID, a summary and the given property lines.
private func vevent(_ lines: String...) -> String {
    "BEGIN:VEVENT\nUID:u1\nSUMMARY:Test\n" + lines.joined(separator: "\n") + "\nEND:VEVENT\n"
}

private func vcal(_ body: String..., header: String = "") -> String {
    "BEGIN:VCALENDAR\nVERSION:2.0\n" + header + body.joined() + "END:VCALENDAR\n"
}

/// The starts of one series: `dtstart` and the RRULE (and other lines) of a single VEVENT.
private func series(_ dtstart: String, _ rrule: String, _ more: String..., now: Date = NOW, horizon: Int = 30, zone: TimeZone = VN) -> [Date] {
    ICS.parse(vcal(vevent([dtstart, "RRULE:" + rrule] + more)), now: now, horizonDays: horizon, zone: zone).events.map(\.start)
}

private func vevent(_ lines: [String]) -> String { "BEGIN:VEVENT\nUID:u1\nSUMMARY:Test\n" + lines.joined(separator: "\n") + "\nEND:VEVENT\n" }

// MARK: fixtures

/// Moodle's calendar export: UTC times, the course in CATEGORIES, escaped text, no RRULE. Two events are outside the window.
private let MOODLE = crlf(#"""
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Moodle Pty Ltd//NONSGML Moodle Version 2024100702//EN
CALSCALE:GREGORIAN
BEGIN:VEVENT
UID:48113@moodle.uni.example
SUMMARY:Assignment 2: Eigenvalues is due
DESCRIPTION:<p>Upload your solutions as one PDF.</p>\n<p>See <a href="https://moodle.uni.example/mod/assign/view.php?id=7731">Assignment 2</a>\, then submit.</p>
CLASS:PUBLIC
LAST-MODIFIED:20261012T081500Z
DTSTAMP:20261020T020000Z
DTSTART:20261023T160000Z
DTEND:20261023T160000Z
CATEGORIES:MATH201 Linear Algebra
END:VEVENT
BEGIN:VEVENT
UID:48120@moodle.uni.example
SUMMARY:Quiz 4: SVD closes
DESCRIPTION:Quiz 4 closes at 20:00.
CLASS:PUBLIC
LAST-MODIFIED:20261001T100000Z
DTSTAMP:20261020T020000Z
DTSTART:20261021T130000Z
DTEND:20261021T130000Z
CATEGORIES:MATH201 Linear Algebra
END:VEVENT
BEGIN:VEVENT
UID:48121@moodle.uni.example
SUMMARY:Quiz 5: Orthogonality opens
DTSTAMP:20261020T020000Z
DTSTART:20261026T010000Z
DTEND:20261026T010000Z
CATEGORIES:MATH201 Linear Algebra
END:VEVENT
BEGIN:VEVENT
UID:48155@moodle.uni.example
SUMMARY:MATH201 midterm exam
DTSTAMP:20261020T020000Z
DTSTART:20261028T020000Z
DTEND:20261028T040000Z
CATEGORIES:MATH201 Linear Algebra
END:VEVENT
BEGIN:VEVENT
UID:49002@moodle.uni.example
SUMMARY:Lab report 3 is due
DTSTAMP:20261020T020000Z
DTSTART:20261102T165900Z
DTEND:20261102T165900Z
CATEGORIES:PHYS102 Mechanics\, Section B
END:VEVENT
BEGIN:VEVENT
UID:47001@moodle.uni.example
SUMMARY:Assignment 1 is due
DTSTAMP:20261020T020000Z
DTSTART:20261005T160000Z
DTEND:20261005T160000Z
CATEGORIES:MATH201 Linear Algebra
END:VEVENT
BEGIN:VEVENT
UID:50999@moodle.uni.example
SUMMARY:Final project is due
DTSTAMP:20261020T020000Z
DTSTART:20261218T160000Z
DTEND:20261218T160000Z
CATEGORIES:CS301 Software Engineering
END:VEVENT
END:VCALENDAR
"""#)

/// An Outlook "publish calendar" export: Windows zone names, a VTIMEZONE block (ignored), a weekly lecture with BYDAY and an
/// EXDATE, one occurrence moved by a RECURRENCE-ID event, an all-day event, a folded subject and body with a VALARM, a
/// monthly series (not simple: skipped) and a cancelled meeting.
private let OUTLOOK = crlf(#"""
BEGIN:VCALENDAR
PRODID:Microsoft Exchange Server 2010
VERSION:2.0
METHOD:PUBLISH
X-WR-CALNAME:Calendar
BEGIN:VTIMEZONE
TZID:W. Europe Standard Time
BEGIN:STANDARD
DTSTART:16010101T030000
TZOFFSETFROM:+0200
TZOFFSETTO:+0100
RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=10
END:STANDARD
BEGIN:DAYLIGHT
DTSTART:16010101T020000
TZOFFSETFROM:+0100
TZOFFSETTO:+0200
RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=3
END:DAYLIGHT
END:VTIMEZONE
BEGIN:VEVENT
RRULE:FREQ=WEEKLY;UNTIL=20261211T090000Z;INTERVAL=1;BYDAY=TU,TH;WKST=MO
UID:040000008200E00074C5B7101A82E00800000000A1B2C3D4E5F6
SUMMARY:MATH201 Lecture
DTSTART;TZID=W. Europe Standard Time:20260908T100000
DTEND;TZID=W. Europe Standard Time:20260908T114500
EXDATE;TZID=W. Europe Standard Time:20261029T100000
LOCATION:Room A1.03
TRANSP:OPAQUE
SEQUENCE:0
DTSTAMP:20260901T081500Z
LAST-MODIFIED:20260901T081500Z
CLASS:PUBLIC
PRIORITY:5
X-MICROSOFT-CDO-BUSYSTATUS:BUSY
X-MICROSOFT-CDO-ALLDAYEVENT:FALSE
END:VEVENT
BEGIN:VEVENT
UID:040000008200E00074C5B7101A82E00800000000A1B2C3D4E5F6
RECURRENCE-ID;TZID=W. Europe Standard Time:20261022T100000
SUMMARY:MATH201 Lecture (moved to B2.10)
DTSTART;TZID=W. Europe Standard Time:20261022T140000
DTEND;TZID=W. Europe Standard Time:20261022T154500
LOCATION:Room B2.10
SEQUENCE:1
DTSTAMP:20261015T120000Z
LAST-MODIFIED:20261015T120000Z
END:VEVENT
BEGIN:VEVENT
UID:040000008200E00074C5B7101A82E0080000000011223344
SUMMARY:Reading week
DTSTART;VALUE=DATE:20261102
DTEND;VALUE=DATE:20261107
X-MICROSOFT-CDO-ALLDAYEVENT:TRUE
TRANSP:TRANSPARENT
END:VEVENT
BEGIN:VEVENT
UID:040000008200E00074C5B7101A82E0080000000055667788
SUMMARY:Project meeting with Dr. Nguy
 en about the thesis proposal
DTSTART;TZID=W. Europe Standard Time:20261021T153000
DTEND;TZID=W. Europe Standard Time:20261021T161500
LOCATION:Microsoft Teams Meeting
DESCRIPTION:Join: https://teams.microsoft.com/l/meetup-join/19%3ameeting_Yz
 Qx%40thread.v2/0?context=%7b%22Tid%22%3a%22abc%22%7d\n\nOr call in (audio
  only)\, ID: 123 456 789#
SEQUENCE:2
LAST-MODIFIED:20261019T101500Z
BEGIN:VALARM
ACTION:DISPLAY
DESCRIPTION:Reminder
TRIGGER:-PT15M
END:VALARM
END:VEVENT
BEGIN:VEVENT
UID:040000008200E00074C5B7101A82E008000000009999AAAA
SUMMARY:Faculty board
RRULE:FREQ=MONTHLY;BYMONTHDAY=1
DTSTART;TZID=W. Europe Standard Time:20260901T140000
DTEND;TZID=W. Europe Standard Time:20260901T150000
END:VEVENT
BEGIN:VEVENT
UID:040000008200E00074C5B7101A82E00800000000BBBBCCCC
SUMMARY:Canceled: Supervision
STATUS:CANCELLED
DTSTART;TZID=W. Europe Standard Time:20261022T090000
DTEND;TZID=W. Europe Standard Time:20261022T093000
END:VEVENT
END:VCALENDAR
"""#)

@Suite struct ICSTests {
    // MARK: Moodle

    @Test func aMoodleFeedGivesItsEventsInTheWindowSortedByStart() {
        let r = ICS.parse(MOODLE, now: NOW, zone: VN)
        #expect(r.skipped == 0)
        #expect(r.events.map(\.summary) == ["Quiz 4: SVD closes", "Assignment 2: Eigenvalues is due", "Quiz 5: Orthogonality opens",
                                            "MATH201 midterm exam", "Lab report 3 is due"])
        #expect(r.events.map(\.start) == [at(2026, 10, 21, 13), at(2026, 10, 23, 16), at(2026, 10, 26, 1), at(2026, 10, 28, 2), at(2026, 11, 2, 16, 59)])
        #expect(r.events.allSatisfy { !$0.isRecurring && !$0.allDay })
    }

    @Test func aMoodleEventKeepsItsFieldsAndUnescapesItsText() throws {
        let e = try #require(ICS.parse(MOODLE, now: NOW, zone: VN).events.first { $0.uid == "48113@moodle.uni.example" })
        #expect(e.categories == "MATH201 Linear Algebra")
        #expect(e.lastModified == at(2026, 10, 12, 8, 15))
        #expect(e.end == at(2026, 10, 23, 16))
        #expect(e.description.contains("\n<p>See <a href=\"https://moodle.uni.example/mod/assign/view.php?id=7731\">"))
        #expect(e.description.contains("Assignment 2</a>, then submit."))  // \, is a comma
        let lab = try #require(ICS.parse(MOODLE, now: NOW, zone: VN).events.first { $0.uid == "49002@moodle.uni.example" })
        #expect(lab.categories == "PHYS102 Mechanics, Section B")
    }

    @Test func theWindowIsADayBeforeNowToTheHorizon() {
        let early = ICS.parse(MOODLE, now: at(2026, 10, 6, 0, 0), zone: VN).events.map(\.uid)
        #expect(early.contains("47001@moodle.uni.example"))  // 2026-10-05 16:00Z is within a day of 2026-10-06 00:00Z
        #expect(!ICS.parse(MOODLE, now: at(2026, 10, 7, 0, 0), zone: VN).events.map(\.uid).contains("47001@moodle.uni.example"))
        #expect(ICS.parse(MOODLE, now: NOW, horizonDays: 60, zone: VN).events.count == 6)  // the project due in December is 59 days out
        #expect(ICS.parse(MOODLE, now: NOW, horizonDays: 2, zone: VN).events.map(\.uid) == ["48120@moodle.uni.example"])
        #expect(ICS.parse(MOODLE, now: NOW, horizonDays: 0, zone: VN).events.isEmpty)
        #expect(ICS.parse(MOODLE, now: NOW, horizonDays: -5, zone: VN).events.isEmpty)
    }

    // MARK: Outlook

    @Test func anOutlookFeedExpandsTheLectureKeepingTenOClockInBerlinAcrossTheDSTChange() {
        let lectures = ICS.parse(OUTLOOK, now: NOW, zone: VN).events.filter { $0.uid.hasSuffix("A1B2C3D4E5F6") }
        // Tue/Thu 10:00 local. 2026-10-22 was moved (14:00, below), 2026-10-29 is an EXDATE. Berlin changes to winter time on 10-25.
        #expect(lectures.map(\.start) == [
            at(2026, 10, 20, 10, 0, BERLIN), at(2026, 10, 22, 14, 0, BERLIN), at(2026, 10, 27, 10, 0, BERLIN),
            at(2026, 11, 3, 10, 0, BERLIN), at(2026, 11, 5, 10, 0, BERLIN), at(2026, 11, 10, 10, 0, BERLIN),
            at(2026, 11, 12, 10, 0, BERLIN), at(2026, 11, 17, 10, 0, BERLIN),
        ])
        #expect(lectures[0].start == at(2026, 10, 20, 8))  // CEST: 08:00Z
        #expect(lectures[2].start == at(2026, 10, 27, 9))  // CET: 09:00Z, the same wall clock
        #expect(lectures.allSatisfy { $0.isRecurring })
    }

    @Test func theMovedOccurrenceReplacesTheSeriesOneAndKeepsItsOwnFields() throws {
        let lectures = ICS.parse(OUTLOOK, now: NOW, zone: VN).events.filter { $0.uid.hasSuffix("A1B2C3D4E5F6") }
        #expect(!lectures.contains { $0.start == at(2026, 10, 22, 10, 0, BERLIN) })  // the original slot is gone
        let moved = try #require(lectures.first { $0.start == at(2026, 10, 22, 14, 0, BERLIN) })
        #expect(moved.summary == "MATH201 Lecture (moved to B2.10)" && moved.location == "Room B2.10" && moved.sequence == 1)
        #expect(moved.end == at(2026, 10, 22, 15, 45, BERLIN))
        let normal = lectures[0]
        #expect(normal.summary == "MATH201 Lecture" && normal.location == "Room A1.03" && normal.sequence == 0)
        #expect(normal.end == normal.start.addingTimeInterval(105 * 60))  // 10:00 to 11:45 on every occurrence
    }

    @Test func exdateDropsOneOccurrenceAndUntilEndsTheSeries() {
        let all = ICS.parse(OUTLOOK, now: NOW, horizonDays: 90, zone: VN).events.filter { $0.uid.hasSuffix("A1B2C3D4E5F6") }
        #expect(!all.contains { $0.start == at(2026, 10, 29, 10, 0, BERLIN) })
        // UNTIL is 2026-12-11 09:00Z, a Friday: the Thursday 12-10 at 10:00 CET is the last occurrence.
        #expect(all.last?.start == at(2026, 12, 10, 10, 0, BERLIN))
        #expect(!all.contains { $0.start > at(2026, 12, 11, 9, 0) })
    }

    @Test func anAllDayEventIsMidnightInTheCallersZoneAndEndsExclusive() throws {
        let e = try #require(ICS.parse(OUTLOOK, now: NOW, zone: VN).events.first { $0.summary == "Reading week" })
        #expect(e.allDay && !e.isRecurring)
        #expect(e.start == at(2026, 11, 2, 0, 0, VN) && e.end == at(2026, 11, 7, 0, 0, VN))
        let other = try #require(ICS.parse(OUTLOOK, now: NOW, zone: NEW_YORK).events.first { $0.summary == "Reading week" })
        #expect(other.start == at(2026, 11, 2, 0, 0, NEW_YORK))  // the zone argument, not the machine's
    }

    @Test func foldedLinesAreJoinedAndTheNestedAlarmDoesNotOverwriteTheEvent() throws {
        let e = try #require(ICS.parse(OUTLOOK, now: NOW, zone: VN).events.first { $0.uid.hasSuffix("55667788") })
        #expect(e.summary == "Project meeting with Dr. Nguyen about the thesis proposal")
        #expect(e.start == at(2026, 10, 21, 15, 30, BERLIN) && e.end == at(2026, 10, 21, 16, 15, BERLIN))
        #expect(e.location == "Microsoft Teams Meeting" && e.sequence == 2)
        #expect(e.description.hasPrefix("Join: https://teams.microsoft.com/l/meetup-join/19%3ameeting_YzQx%40thread.v2/0?context="))
        #expect(e.description.contains("\n\nOr call in (audio only), ID: 123 456 789#"))  // the fold with two spaces keeps one
        #expect(e.description != "Reminder")
    }

    @Test func aMonthlySeriesIsSkippedAndCountedAndACancelledMeetingIsDroppedQuietly() {
        let r = ICS.parse(OUTLOOK, now: NOW, zone: VN)
        #expect(r.skipped == 1)
        #expect(!r.events.contains { $0.summary == "Faculty board" || $0.summary.hasPrefix("Canceled") })
        #expect(r.events.count == 10)  // 8 lectures, the all-day event, the project meeting
    }

    @Test func aCancelledSingleOccurrenceDropsThatOccurrenceOfTheSeries() {
        let text = vcal(
            vevent("DTSTART;TZID=Europe/Berlin:20261020T100000", "RRULE:FREQ=WEEKLY;COUNT=4"),
            "BEGIN:VEVENT\nUID:u1\nRECURRENCE-ID;TZID=Europe/Berlin:20261027T100000\nSTATUS:CANCELLED\nDTSTART;TZID=Europe/Berlin:20261027T100000\nEND:VEVENT\n")
        let starts = ICS.parse(text, now: NOW, zone: VN).events.map(\.start)
        #expect(starts == [at(2026, 10, 20, 10, 0, BERLIN), at(2026, 11, 3, 10, 0, BERLIN), at(2026, 11, 10, 10, 0, BERLIN)])
    }

    // MARK: zones

    /// Winter 2026-01-15 09:00 local in each zone Outlook might name, as the UTC instant.
    @Test(arguments: [
        ("W. Europe Standard Time", at(2026, 1, 15, 8)), ("Eastern Standard Time", at(2026, 1, 15, 14)),
        ("Arabian Standard Time", at(2026, 1, 15, 5)), ("GMT Standard Time", at(2026, 1, 15, 9)),
        ("Pacific Standard Time", at(2026, 1, 15, 17)), ("India Standard Time", at(2026, 1, 15, 3, 30)),
        ("China Standard Time", at(2026, 1, 15, 1)), ("Tokyo Standard Time", at(2026, 1, 15, 0)),
        ("AUS Eastern Standard Time", at(2026, 1, 14, 22)), ("SE Asia Standard Time", at(2026, 1, 15, 2)),
        ("America/New_York", at(2026, 1, 15, 14)), ("Europe/Berlin", at(2026, 1, 15, 8)), ("UTC", at(2026, 1, 15, 9)),
        ("Customized Time Zone", at(2026, 1, 15, 2)),  // unknown: the caller's zone (Vietnam, UTC+7)
        ("", at(2026, 1, 15, 2)),
    ] as [(String, Date)])
    func aZoneNameIsMappedAndAnUnknownOneFallsBackToTheCallersZone(tzid: String, want: Date) {
        let line = tzid.isEmpty ? "DTSTART:20260115T090000" : "DTSTART;TZID=\(tzid):20260115T090000"
        let r = ICS.parse(vcal(vevent(line)), now: at(2026, 1, 15), zone: VN)
        #expect(r.events.map(\.start) == [want], "\(tzid)")
    }

    @Test func aQuotedTZIDAndAZSuffixAreRead() {
        let r = ICS.parse(vcal(vevent("DTSTART;TZID=\"Europe/Berlin\":20260115T090000"), vevent("DTSTART:20260115T090000Z")), now: at(2026, 1, 15), zone: VN)
        #expect(r.events.map(\.start) == [at(2026, 1, 15, 8), at(2026, 1, 15, 9)])
    }

    @Test func aFloatingTimeTakesTheZoneArgumentAndTheFeedsOwnDefaultComesFirst() {
        let floating = vcal(vevent("DTSTART:20261021T100000"))
        #expect(ICS.parse(floating, now: NOW, zone: VN).events.map(\.start) == [at(2026, 10, 21, 10, 0, VN)])
        #expect(ICS.parse(floating, now: NOW, zone: NEW_YORK).events.map(\.start) == [at(2026, 10, 21, 10, 0, NEW_YORK)])
        let own = vcal(vevent("DTSTART:20261021T100000"), header: "X-WR-TIMEZONE:Europe/Berlin\n")
        #expect(ICS.parse(own, now: NOW, zone: VN).events.map(\.start) == [at(2026, 10, 21, 10, 0, BERLIN)])
        let windows = vcal(vevent("DTSTART:20261021T100000"), header: "X-WR-TIMEZONE:W. Europe Standard Time\n")
        #expect(ICS.parse(windows, now: NOW, zone: VN).events.map(\.start) == [at(2026, 10, 21, 10, 0, BERLIN)])
        let bad = vcal(vevent("DTSTART:20261021T100000"), header: "X-WR-TIMEZONE:Mars/Olympus\n")
        #expect(ICS.parse(bad, now: NOW, zone: VN).events.map(\.start) == [at(2026, 10, 21, 10, 0, VN)])
    }

    // MARK: recurrence rules

    @Test func everyOtherWeekOnMondayAndWednesday() {
        let got = series("DTSTART:20261005T090000Z", "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE")
        #expect(got == [at(2026, 10, 19, 9), at(2026, 10, 21, 9), at(2026, 11, 2, 9), at(2026, 11, 4, 9), at(2026, 11, 16, 9), at(2026, 11, 18, 9)])
    }

    @Test func countCountsTheOccurrencesBeforeTheWindowToo() {
        #expect(series("DTSTART:20261019T090000Z", "FREQ=WEEKLY;COUNT=3;BYDAY=MO,WE") == [at(2026, 10, 19, 9), at(2026, 10, 21, 9), at(2026, 10, 26, 9)])
        // 10-05, 10-07, 10-12, 10-14 and 10-19 are the five; only the last is in the window.
        #expect(series("DTSTART:20261005T090000Z", "FREQ=WEEKLY;COUNT=5;BYDAY=MO,WE") == [at(2026, 10, 19, 9)])
        #expect(series("DTSTART:20261005T090000Z", "FREQ=WEEKLY;COUNT=4;BYDAY=MO,WE").isEmpty)
        // Daily from 09-01: the 50th is 10-20, so the 49th (10-19) and the 50th are the only ones in the window.
        #expect(series("DTSTART:20260901T090000Z", "FREQ=DAILY;COUNT=50") == [at(2026, 10, 19, 9), at(2026, 10, 20, 9)])
        #expect(series("DTSTART:20260901T090000Z", "FREQ=DAILY;COUNT=40").isEmpty)  // over on 10-10
    }

    @Test func untilIsInclusiveAndADateOnlyUntilEndsAfterThatDay() {
        #expect(series("DTSTART:20261005T090000Z", "FREQ=WEEKLY;UNTIL=20261022T090000Z") == [at(2026, 10, 19, 9)])
        #expect(series("DTSTART:20261005T090000Z", "FREQ=WEEKLY;UNTIL=20261026T090000Z") == [at(2026, 10, 19, 9), at(2026, 10, 26, 9)])
        #expect(series("DTSTART:20261005T090000Z", "FREQ=WEEKLY;UNTIL=20261026") == [at(2026, 10, 19, 9), at(2026, 10, 26, 9)])
        #expect(series("DTSTART:20261005T090000Z", "FREQ=WEEKLY;UNTIL=20261025") == [at(2026, 10, 19, 9)])
        #expect(series("DTSTART:20260901T090000Z", "FREQ=WEEKLY;UNTIL=20261001T000000Z").isEmpty)  // over before the window
    }

    @Test func dailyEveryThirdDayAndEveryWeekdayAndWithAnOptionalWeekdayList() {
        #expect(series("DTSTART:20261001T090000Z", "FREQ=DAILY;INTERVAL=3") == [
            at(2026, 10, 19, 9), at(2026, 10, 22, 9), at(2026, 10, 25, 9), at(2026, 10, 28, 9), at(2026, 10, 31, 9),
            at(2026, 11, 3, 9), at(2026, 11, 6, 9), at(2026, 11, 9, 9), at(2026, 11, 12, 9), at(2026, 11, 15, 9), at(2026, 11, 18, 9),
        ])
        let weekdays = series("DTSTART:20261016T090000Z", "FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = UTC
        #expect(weekdays.count == 23 && weekdays.allSatisfy { (2...6).contains(utc.component(.weekday, from: $0)) })
        #expect(weekdays.first == at(2026, 10, 19, 9) && weekdays.last == at(2026, 11, 18, 9))
    }

    @Test func theWeekStartDecidesWhichWeeksAreSkippedWhenTheIntervalIsTwo() {
        // 2026-10-18 is a Sunday. With weeks starting on Monday, Sunday is the end of its week and Monday starts the next
        // counted one; with weeks starting on Sunday, Sunday and Monday share a week.
        #expect(series("DTSTART:20261018T090000Z", "FREQ=WEEKLY;INTERVAL=2;BYDAY=SU,MO;WKST=MO")
            == [at(2026, 10, 26, 9), at(2026, 11, 1, 9), at(2026, 11, 9, 9), at(2026, 11, 15, 9)])
        #expect(series("DTSTART:20261018T090000Z", "FREQ=WEEKLY;INTERVAL=2;BYDAY=SU,MO;WKST=SU")
            == [at(2026, 10, 19, 9), at(2026, 11, 1, 9), at(2026, 11, 2, 9), at(2026, 11, 15, 9), at(2026, 11, 16, 9)])
    }

    @Test func aWeeklyRuleWithoutBYDAYRepeatsOnTheStartsWeekday() {
        #expect(series("DTSTART:20261014T090000Z", "FREQ=WEEKLY") == [at(2026, 10, 21, 9), at(2026, 10, 28, 9), at(2026, 11, 4, 9), at(2026, 11, 11, 9), at(2026, 11, 18, 9)])
    }

    @Test func aSeriesThatStartsInTheFutureHasNothingBeforeItsStart() {
        #expect(series("DTSTART:20261028T090000Z", "FREQ=WEEKLY;BYDAY=MO,WE,FR") == [at(2026, 10, 28, 9), at(2026, 10, 30, 9), at(2026, 11, 2, 9), at(2026, 11, 4, 9),
                                                                                      at(2026, 11, 6, 9), at(2026, 11, 9, 9), at(2026, 11, 11, 9), at(2026, 11, 13, 9),
                                                                                      at(2026, 11, 16, 9), at(2026, 11, 18, 9)])
    }

    @Test func aSeriesInAZoneKeepsItsWallClockAcrossBothDSTChangesAndAUTCOneKeepsUTC() {
        let berlin = series("DTSTART;TZID=Europe/Berlin:20261019T100000", "FREQ=WEEKLY")
        #expect(berlin == [at(2026, 10, 19, 10, 0, BERLIN), at(2026, 10, 26, 10, 0, BERLIN), at(2026, 11, 2, 10, 0, BERLIN), at(2026, 11, 9, 10, 0, BERLIN), at(2026, 11, 16, 10, 0, BERLIN)])
        #expect(berlin.map { Calendar.current.dateComponents(in: UTC, from: $0).hour } == [8, 9, 9, 9, 9])
        #expect(series("DTSTART:20261019T100000Z", "FREQ=WEEKLY").map { Calendar.current.dateComponents(in: UTC, from: $0).hour } == [10, 10, 10, 10, 10])
    }

    @Test func aTimeThatDoesNotExistOnTheSpringForwardDayStillGivesOneOccurrence() {
        let got = series("DTSTART;TZID=America/New_York:20260301T023000", "FREQ=WEEKLY", now: at(2026, 3, 7, 12), horizon: 10)
        #expect(got.count == 2)  // 03-08 (02:30 does not exist: it moves to 03:30) and 03-15
        #expect(got[1] == at(2026, 3, 15, 2, 30, NEW_YORK))
        #expect(got[0] >= at(2026, 3, 8, 7) && got[0] <= at(2026, 3, 8, 8))
    }

    @Test func exdateTakesSeveralValuesAndSeveralLines() {
        let got = series("DTSTART:20261019T090000Z", "FREQ=DAILY;COUNT=8", "EXDATE:20261021T090000Z,20261022T090000Z", "EXDATE:20261024T090000Z")
        #expect(got == [at(2026, 10, 19, 9), at(2026, 10, 20, 9), at(2026, 10, 23, 9), at(2026, 10, 25, 9), at(2026, 10, 26, 9)])
    }

    @Test func aSeriesIsCappedAtTwoHundredOccurrences() {
        let got = series("DTSTART:20261019T090000Z", "FREQ=DAILY", horizon: 3650)
        #expect(got.count == ICS.maxOccurrences && got.first == at(2026, 10, 19, 9))
    }

    /// Rules beyond DAILY/WEEKLY with BYDAY: the event is skipped and counted, not guessed.
    @Test(arguments: [
        "FREQ=MONTHLY;BYMONTHDAY=15", "FREQ=MONTHLY", "FREQ=YEARLY;BYMONTH=10", "FREQ=MONTHLY;BYDAY=2TU", "FREQ=MONTHLY;BYDAY=TU;BYSETPOS=2",
        "FREQ=WEEKLY;BYDAY=1MO", "FREQ=WEEKLY;BYDAY=-1FR", "FREQ=DAILY;BYSETPOS=1", "FREQ=HOURLY;INTERVAL=2", "FREQ=WEEKLY;BYMONTH=10",
        "FREQ=WEEKLY;BYHOUR=9", "FREQ=SECONDLY", "FREQ=WEEKLY;INTERVAL=0", "FREQ=WEEKLY;INTERVAL=1001", "FREQ=WEEKLY;INTERVAL=x", "FREQ=WEEKLY;COUNT=0",
        "FREQ=WEEKLY;COUNT=99999999999999999999", "FREQ=WEEKLY;UNTIL=garbage", "FREQ=WEEKLY;BYDAY=XX", "FREQ=WEEKLY;WKST=ZZ", "INTERVAL=2", "", "FREQ", "NONSENSE",
    ])
    func rulesBeyondTheSimpleOnesAreSkipped(_ rule: String) {
        let r = ICS.parse(vcal(vevent("DTSTART:20261019T090000Z", "RRULE:" + rule)), now: NOW, zone: VN)
        #expect(r.events.isEmpty && r.skipped == 1, "\(rule)")
    }

    // MARK: single events, bad data

    @Test(arguments: [
        "", "DTSTART:", "DTSTART:garbage", "DTSTART:20261301T100000Z", "DTSTART:20260230T100000Z", "DTSTART:20261021T250000Z",
        "DTSTART:20261021T106000Z", "DTSTART:2026-10-21T10:00:00Z", "DTSTART:20261021T1000Z", "DTSTART:19690101T000000Z",
        "DTSTART:99991231T000000Z", "DTSTART:2026102100000Z", "DTSTART:20261021Z", "DTSTART:20261021T10000AZ", "SUMMARY:no start",
    ])
    func aBadStartSkipsTheEventAndTheNextOneStillParses(_ line: String) {
        let text = vcal(vevent(line), "BEGIN:VEVENT\nUID:good\nSUMMARY:Good\nDTSTART:20261022T100000Z\nEND:VEVENT\n")
        let r = ICS.parse(text, now: NOW, zone: VN)
        #expect(r.events.map(\.uid) == ["good"] && r.skipped == 1, "\(line)")
    }

    @Test func aPlainDateIsAValidAllDayStart() {
        let r = ICS.parse(vcal(vevent("DTSTART:20261021")), now: NOW, zone: VN)
        #expect(r.events.count == 1 && r.events[0].allDay && r.skipped == 0)
    }

    @Test func anEventWithoutAUIDGetsOneFromItsSubjectAndStart() {
        let one = "BEGIN:VEVENT\nSUMMARY:No uid\nDTSTART:20261021T100000Z\nEND:VEVENT\n"
        let two = "BEGIN:VEVENT\nSUMMARY:No uid\nDTSTART:20261022T100000Z\nEND:VEVENT\n"
        let r = ICS.parse(vcal(one, two), now: NOW, zone: VN)
        #expect(r.events.count == 2 && r.events[0].uid != r.events[1].uid && !r.events[0].uid.isEmpty)
    }

    @Test func anUnterminatedEventIsSkippedAndTheOneAfterItSurvives() {
        let text = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:a\nSUMMARY:Never ends\nDTSTART:20261021T100000Z\nBEGIN:VEVENT\nUID:b\nSUMMARY:Fine\nDTSTART:20261022T100000Z\nEND:VEVENT\nEND:VCALENDAR\n"
        let r = ICS.parse(text, now: NOW, zone: VN)
        #expect(r.events.map(\.uid) == ["b"] && r.skipped == 1)
    }

    @Test func anEventCutOffAtTheEndOfTheFileIsSkipped() {
        for tail in ["", "UID:a\n", "UID:a\nSUMMARY:x\nDTSTART:20261021T100000Z\n", "UID:a\nSUMMARY:x\nDTSTART:20261021T100000Z"] {
            let r = ICS.parse("BEGIN:VCALENDAR\nBEGIN:VEVENT\n" + tail, now: NOW, zone: VN)
            #expect(r.events.isEmpty && r.skipped == 1, "\(tail)")
        }
        let closedByTheCalendar = ICS.parse("BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:a\nDTSTART:20261021T100000Z\nEND:VCALENDAR\n", now: NOW, zone: VN)
        #expect(closedByTheCalendar.events.isEmpty && closedByTheCalendar.skipped == 1)
    }

    @Test func textThatIsNotACalendarGivesNothing() {
        for text in ["", "\n\n\n", "hello", "BEGIN:VCALENDAR", "END:VEVENT\nEND:VEVENT\n", "UID:1\nSUMMARY:x\nDTSTART:20261021T100000Z\n",
                     "BEGIN:VCALENDAR\nBEGIN:VTODO\nUID:1\nSUMMARY:todo\nDTSTART:20261021T100000Z\nEND:VTODO\nEND:VCALENDAR\n"] {
            let r = ICS.parse(text, now: NOW, zone: VN)
            #expect(r.events.isEmpty && r.skipped == 0, "\(text)")
        }
    }

    @Test func aStartAfterTheEndKeepsNoEnd() throws {
        let e = try #require(ICS.parse(vcal(vevent("DTSTART:20261021T100000Z", "DTEND:20261021T090000Z")), now: NOW, zone: VN).events.first)
        #expect(e.end == nil)
        let none = try #require(ICS.parse(vcal(vevent("DTSTART:20261021T100000Z")), now: NOW, zone: VN).events.first)
        #expect(none.end == nil && none.sequence == nil && none.lastModified == nil && none.summary == "Test")
    }

    // MARK: hostile input

    @Test func aHugeFileIsCappedAtFiveThousandEventsAndStaysFast() {
        let block = "BEGIN:VEVENT\r\nUID:u\r\nSUMMARY:Spam\r\nDTSTART:20261022T100000Z\r\nEND:VEVENT\r\n"
        let text = "BEGIN:VCALENDAR\r\n" + String(repeating: block, count: 12_000) + "END:VCALENDAR\r\n"
        let started = ContinuousClock.now
        let r = ICS.parse(text, now: NOW, zone: VN)
        #expect(r.events.count == ICS.maxEvents && r.skipped == 12_000 - ICS.maxEvents)
        #expect(ContinuousClock.now - started < .seconds(30))
    }

    @Test func inputPastTheByteCapIsIgnored() {
        let junk = String(repeating: "X-JUNK:" + String(repeating: "a", count: 1000) + "\r\n", count: 5000)  // 5 MB
        let event = "BEGIN:VEVENT\r\nUID:late\r\nDTSTART:20261022T100000Z\r\nEND:VEVENT\r\n"
        let started = ContinuousClock.now
        #expect(ICS.parse("BEGIN:VCALENDAR\r\n" + junk + event + "END:VCALENDAR\r\n", now: NOW, zone: VN).events.isEmpty)
        #expect(ICS.parse("BEGIN:VCALENDAR\r\n" + event + junk + "END:VCALENDAR\r\n", now: NOW, zone: VN).events.map(\.uid) == ["late"])
        #expect(ContinuousClock.now - started < .seconds(30))
    }

    @Test func oneEnormousLineIsTruncatedAndTheSummaryKeepsThreeHundredCharacters() throws {
        let huge = String(repeating: "x", count: 1_500_000)  // two of them stay under the byte cap
        let text = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:big\nSUMMARY:" + huge + "\nDESCRIPTION:" + huge + "\nDTSTART:20261022T100000Z\nEND:VEVENT\nEND:VCALENDAR\n"
        let e = try #require(ICS.parse(text, now: NOW, zone: VN).events.first)
        #expect(e.summary.count == 300 && e.description.count == 4000)
    }

    @Test func binaryJunkGivesNothingAndDoesNotCrash() {
        var gen = SplitMix64(seed: 7)
        let bytes = (0..<300_000).map { _ in UInt8.random(in: 0...255, using: &gen) }
        #expect(ICS.parse(Data(bytes), now: NOW, zone: VN).events.isEmpty)
        let framed = Data("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\n".utf8) + Data(bytes) + Data("\r\nEND:VCALENDAR\r\n".utf8)
        #expect(ICS.parse(framed, now: NOW, zone: VN).events.isEmpty)
        #expect(ICS.parse(String(decoding: bytes, as: UTF8.self), now: NOW, zone: VN).events.isEmpty)
    }

    @Test func absurdCountsAndIntervalsAreBoundedNotLooped() {
        // COUNT in the billions: the window still gives its 30 days of occurrences, quickly.
        let started = ContinuousClock.now
        let near = series("DTSTART:20261001T090000Z", "FREQ=DAILY;COUNT=2000000000")
        #expect(near.count == 31 && near.first == at(2026, 10, 19, 9))
        // A start in 1970 with a huge COUNT would have to walk 20,000 days to reach the window: it gives up, empty.
        #expect(series("DTSTART:19700101T090000Z", "FREQ=DAILY;COUNT=2000000000").isEmpty)
        // A weekly rule walks a week a step, so 56 years (about 2,900 steps) are within reach.
        #expect(series("DTSTART:19700101T090000Z", "FREQ=WEEKLY;COUNT=2000000000;BYDAY=MO,TU,WE,TH,FR,SA,SU").count == 31)
        // Without a COUNT the walk jumps to the window.
        #expect(series("DTSTART:19700101T090000Z", "FREQ=DAILY").count == 31)
        #expect(series("DTSTART:20261001T090000Z", "FREQ=DAILY;INTERVAL=1000") == [])
        #expect(ContinuousClock.now - started < .seconds(30))
    }

    @Test func manyHostileSeriesShareOneWorkBudget() {
        let block = "BEGIN:VEVENT\nUID:s\nSUMMARY:S\nDTSTART:19700101T090000Z\nRRULE:FREQ=DAILY;COUNT=2000000000\nEND:VEVENT\n"
        let started = ContinuousClock.now
        let r = ICS.parse("BEGIN:VCALENDAR\n" + String(repeating: block, count: 2000) + "END:VCALENDAR\n", now: NOW, zone: VN)
        #expect(r.events.isEmpty)
        #expect(r.skipped > 0)  // the budget ran out: the rest are counted, not walked
        #expect(ContinuousClock.now - started < .seconds(30))
    }

    @Test func deeplyNestedBeginsDoNotCrash() {
        let text = "BEGIN:VCALENDAR\n" + String(repeating: "BEGIN:X\n", count: 10_000) + "BEGIN:VEVENT\nUID:n\nDTSTART:20261022T100000Z\nEND:VEVENT\n" + String(repeating: "END:X\n", count: 10_000)
        _ = ICS.parse(text, now: NOW, zone: VN)
    }

    // MARK: lines

    @Test func aFoldInsideAMultiByteCharacterIsUndoneOnBytes() throws {
        var data = Data("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:f1\r\nDTSTART:20261021T100000Z\r\nSUMMARY:Caf".utf8)
        data.append(0xC3)  // the first byte of é, then the fold, then the second byte
        data.append(contentsOf: Array("\r\n ".utf8))
        data.append(0xA9)
        data.append(contentsOf: Array(" exam\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8))
        #expect(try #require(ICS.parse(data, now: NOW, zone: VN).events.first).summary == "Café exam")
    }

    @Test func aByteOrderMarkLineEndingsAndTabFoldsAreAccepted() throws {
        let body = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:x\nSUMMARY:Tab\n\tbed\nDTSTART:20261021T100000Z\nEND:VEVENT\nEND:VCALENDAR\n"
        for text in ["\u{FEFF}" + body, body.replacingOccurrences(of: "\n", with: "\r\n"), body.replacingOccurrences(of: "\n", with: "\r"), body.replacingOccurrences(of: "\n", with: "\n\n")] {
            #expect(try #require(ICS.parse(text, now: NOW, zone: VN).events.first).summary == "Tabbed", "\(text.debugDescription)")
        }
    }

    @Test(arguments: [
        ("SUMMARY:Hello", "SUMMARY", [:], "Hello"),
        ("summary:lower", "SUMMARY", [:], "lower"),
        ("SUMMARY;LANGUAGE=en:Hello", "SUMMARY", ["LANGUAGE": "en"], "Hello"),
        ("DTSTART;TZID=W. Europe Standard Time:20260908T100000", "DTSTART", ["TZID": "W. Europe Standard Time"], "20260908T100000"),
        ("DTSTART;TZID=\"(UTC+01:00) Amsterdam; Berlin\":20260908T100000", "DTSTART", ["TZID": "(UTC+01:00) Amsterdam; Berlin"], "20260908T100000"),
        ("ATTENDEE;CN=\"Doe, John: PhD\";ROLE=REQ-PARTICIPANT:mailto:j@x.example", "ATTENDEE", ["CN": "Doe, John: PhD", "ROLE": "REQ-PARTICIPANT"], "mailto:j@x.example"),
        ("DESCRIPTION:a:b:c", "DESCRIPTION", [:], "a:b:c"),
        ("X-EMPTY:", "X-EMPTY", [:], ""),
    ] as [(String, String, [String: String], String)])
    func aPropertyLineSplitsIntoNameParametersAndValue(line: String, name: String, params: [String: String], value: String) throws {
        let parts = try #require(ICS.split(line))
        #expect(parts.name == name && parts.params == params && parts.value == value)
    }

    @Test(arguments: ["", "no colon here", ":value", ";TZID=x:y", "\"unclosed:quote"])
    func aLineWithoutANameAndColonIsNotAProperty(_ line: String) {
        #expect(ICS.split(line) == nil)
    }

    @Test(arguments: [
        ("plain", "plain"), ("a\\nb", "a\nb"), ("a\\Nb", "a\nb"), ("a\\,b\\;c", "a,b;c"), ("back\\\\slash", "back\\slash"),
        ("\\\\n", "\\n"), ("trailing\\", "trailing"), ("\\x", "x"), ("", ""),
    ])
    func textEscapesAreUndone(_ raw: String, _ want: String) {
        #expect(ICS.unescape(raw) == want)
    }
}
