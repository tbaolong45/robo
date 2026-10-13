// Port of tests/test_plan.py, plus parity checks against the Python implementation (3.14): 30 fixtures
// (input and exact output of `robo plan`), and tables of what datetime/date/time.fromisoformat and
// json.loads accept, return or say. Every expectation marked "Python" was produced by running it.
import Foundation
import Testing
@testable import RoboCore

private let dxb = PlanZone(name: "Asia/Dubai")!
private let newYork = PlanZone(name: "America/New_York")!

private func at(_ hm: String, day: Int = 12) -> PlanTime {
    let p = hm.split(separator: ":").map { Int($0)! }
    return PlanTime(2026, 10, day, p[0], p[1], zone: dxb)
}

private func busy(_ spans: [String]) -> [PlanBusy] {
    spans.map { s in
        let p = s.split(separator: "-").map(String.init)
        return PlanBusy(at(p[0]), at(p[1]))
    }
}

private func task(_ id: String, _ minutes: Int = 60, deadline: String? = nil, priority: Double = 0.5) -> PlanTask {
    try! PlanTask(id: id, title: id.capitalized, minutes: minutes, deadline: deadline.map { at($0) }, priority: priority)
}

private func plan(_ tasks: [PlanTask], _ spans: [String] = [], now: String = "07:00", maxBlock: Int = 90,
                  breakMin: Int = 10) -> [PlanBlock] {
    planDay(tasks, busy(spans), dayStart: at("08:00"), dayEnd: at("22:00"), now: at(now), maxBlock: maxBlock, breakMin: breakMin)
}

private func mins(_ b: PlanBlock) -> Int { b.end.minus(b.start) / 60_000_000 }

/// "id:minutes" for every task the plan could not place completely.
private func left(_ tasks: [PlanTask], _ blocks: [PlanBlock]) -> [String] {
    unscheduled(tasks, blocks).map { "\($0.task.id):\($0.minutes)" }
}

private func windows(_ slots: [(start: PlanTime, end: PlanTime)]) -> [[PlanTime]] { slots.map { [$0.start, $0.end] } }

// MARK: - free_slots

@Test func freeSlotsSubtractsBusyAndClipsToTheDay() {
    let spans = ["07:00-08:30", "10:00-11:00", "10:30-12:00", "12:00-12:30", "13:00-13:00", "21:00-23:00"]
    // straddles the start, overlaps, abuts, zero-width, straddles the end
    let got = freeSlots(busy(spans), dayStart: at("08:00"), dayEnd: at("22:00"))
    #expect(windows(got) == [[at("08:30"), at("10:00")], [at("12:30"), at("21:00")]])
}

@Test func freeSlotsKeepsGapsOfExactlyTheMinimumAndDropsShorter() {
    let got = freeSlots(busy(["08:20-09:00", "09:25-22:00"]), dayStart: at("08:00"), dayEnd: at("22:00"), minMinutes: 25)
    #expect(windows(got) == [[at("09:00"), at("09:25")]])
}

@Test func freeSlotsEmptyCalendarAndEmptyWindow() {
    #expect(windows(freeSlots([], dayStart: at("08:00"), dayEnd: at("22:00"))) == [[at("08:00"), at("22:00")]])
    #expect(freeSlots([], dayStart: at("22:00"), dayEnd: at("08:00")).isEmpty)
}

// A naive datetime cannot be built here (PlanTime always has a zone), so "naive datetimes are rejected" is
// settled by the types; the CLI reads a time without an offset in the plan's zone (see the fixtures).

@Test func taskRejectsBadFields() {
    // minutes 1.5 and a deadline without a zone are not expressible; the JSON path reports them (fixtures)
    #expect(throws: PlanError("minutes must be a positive whole number")) { try PlanTask(id: "a", title: "A", minutes: 0) }
    #expect(throws: PlanError("priority must be a number from 0 to 1")) { try PlanTask(id: "a", title: "A", minutes: 30, priority: 1.5) }
    #expect(throws: PlanError("priority must be a number from 0 to 1")) { try PlanTask(id: "a", title: "A", minutes: 30, priority: .nan) }
    #expect(throws: Never.self) { try PlanTask(id: "a", title: "A", minutes: 1, priority: 1) }
}

// MARK: - plan_day

@Test func blocksNeverOverlapBusyTimeOrEachOther() {
    let spans = ["09:00-10:30", "12:00-13:00", "13:00-14:00", "15:00-15:30", "15:15-16:00", "18:40-19:10"]
    let tasks = [task("a", 200, priority: 0.9), task("b", 60), task("c", 45, priority: 0.2),
                 task("d", 120), task("e", 300, priority: 0.1)]
    let blocks = plan(tasks, spans)
    #expect(blocks.count >= 6)
    for b in blocks {
        #expect(at("08:00") <= b.start && b.start < b.end && b.end <= at("22:00"))
        for x in busy(spans) { #expect(b.end <= x.start || b.start >= x.end) }
    }
    #expect(zip(blocks, blocks.dropFirst()).allSatisfy { $0.end <= $1.start })
}

@Test func nothingIsScheduledAfterItsDeadline() {
    let tasks = [task("essay", 90, deadline: "12:00", priority: 0.9), task("quiz", 30, deadline: "11:45"),
                 task("late", 30, deadline: "06:00"), task("open", 60, priority: 0.1)]
    let blocks = plan(tasks, ["08:00-11:00"])
    let due = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.deadline) })
    #expect(blocks.allSatisfy { b in due[b.taskId]!.map { b.end <= $0 } ?? true })
    #expect(blocks.map(\.taskId) == ["quiz", "open"])
    #expect(left(tasks, blocks) == ["essay:90", "late:30"])
}

@Test func partialFitReportsTheExactMinutesLeftOver() {
    let tasks = [task("a", 200, deadline: "11:30")]
    let blocks = plan(tasks)
    #expect(blocks.map(mins) == [67, 67])
    #expect(left(tasks, blocks) == ["a:66"])
}

@Test func longTasksSplitIntoCappedBlocksWithBreaksBetween() {
    let blocks = plan([task("a", 200), task("b", 30)])
    #expect(blocks[0].start == at("08:00"))
    #expect(blocks.filter { $0.taskId == "a" }.map(mins) == [67, 67, 66])
    #expect(zip(blocks, blocks.dropFirst()).allSatisfy { $1.start.minus($0.end) >= 10 * 60_000_000 })
    let tuned = plan([task("a", 100)], maxBlock: 50, breakMin: 15)
    #expect(tuned.map(mins) == [50, 50])
    #expect(tuned[1].start.minus(tuned[0].end) >= 15 * 60_000_000)
}

@Test func nothingStartsBeforeNowAndStartsLandOnFiveMinutes() {
    let blocks = plan([task("a", 30), task("b", 30)], now: "10:03")
    #expect(blocks[0].start == at("10:05"))
    #expect(blocks.allSatisfy { $0.start >= at("10:03") && ($0.start.wall / 60_000_000) % 5 == 0 })
}

@Test func priorityThenNearestDeadlineWinsTheScarceWindow() {
    let oneHour = ["09:00-22:00"]
    #expect(plan([task("low", priority: 0.2), task("high", priority: 0.9)], oneHour)[0].taskId == "high")
    #expect(plan([task("later", deadline: "20:00"), task("sooner", deadline: "18:00")], oneHour)[0].taskId == "sooner")
    #expect(plan([task("open"), task("dated", deadline: "20:00")], oneHour)[0].taskId == "dated")
}

@Test func sameInputInAnyOrderGivesTheSamePlan() {
    let spans = ["09:00-10:30", "13:00-14:00"]
    let tasks = [task("a", 120, priority: 0.7), task("b", 60, priority: 0.7), task("c", 90, deadline: "20:00")]
    let first = plan(tasks, spans)
    func key(_ b: [PlanBlock]) -> [String] { b.map { "\($0.taskId) \($0.start.isoMinutes) \($0.end.isoMinutes)" } }
    #expect(key(plan(Array(tasks.reversed()), Array(spans.reversed()))) == key(first))
    #expect(key(plan(tasks, spans)) == key(first))
}

// MARK: - datetime semantics (Python)

@Test func timesInOneZoneCountWallClockMinutesAcrossADSTChange() {
    // datetime arithmetic in a ZoneInfo zone ignores the transition
    let a = PlanTime(2026, 3, 8, 1, 30, zone: newYork)
    let later = a.adding(minutes: 60)
    #expect(later.isoMinutes == "2026-03-08T02:30-05:00")  // a time that does not exist, offset from before the change
    let c = PlanTime(2026, 3, 8, 3, 30, zone: newYork)
    #expect(c.minus(a) == 120 * 60_000_000)  // wall difference, ...
    #expect(c.instant - a.instant == 60 * 60_000_000)  // ... though one hour went by
    #expect(PlanTime(2026, 3, 8, 2, 30, zone: newYork).offset == -5 * 3600 * 1_000_000)
    #expect(PlanTime(wall: PlanTime(2026, 3, 8, 2, 30, zone: newYork).wall, zone: newYork, fold: 1).offset == -4 * 3600 * 1_000_000)
}

@Test func aRepeatedHourIsToldApartByFold() {
    let d = PlanTime(2026, 11, 1, 1, 30, zone: newYork)
    let e = PlanTime(wall: d.wall, zone: newYork, fold: 1)
    #expect(d.isoMinutes == "2026-11-01T01:30-04:00" && e.isoMinutes == "2026-11-01T01:30-05:00")
    #expect(e.minus(d) == 0 && e == d)  // same zone: wall clock, fold ignored
    #expect(d.converted(to: .fixed(0)).isoMinutes == "2026-11-01T05:30+00:00" && e.converted(to: .fixed(0)).isoMinutes == "2026-11-01T06:30+00:00")
    #expect(e.converted(to: .fixed(0)).converted(to: newYork).fold == 1)  // converting back finds the second one
    #expect(d.converted(to: .fixed(0)).converted(to: newYork).fold == 0)
    // against a fixed offset, a time that happens twice equals nothing (PEP 495), but orders by instant
    let f = PlanTime(2026, 11, 1, 1, 30, zone: .fixed(-4 * 3600 * 1_000_000))
    #expect(f != d && f != e && f < e && f.converted(to: newYork).isoMinutes == "2026-11-01T01:30-04:00")
}

@Test func timesInDifferentZonesCompareAndSubtractByInstant() {
    let kolkata = PlanTime(2026, 10, 12, 9, 0, zone: .fixed(19_800_000_000))
    #expect(kolkata.minus(PlanTime(2026, 10, 12, 8, 0, zone: dxb)) == -30 * 60_000_000)
    #expect(PlanTime(2026, 10, 12, 9, 0, zone: .fixed(14_430_250_000)).isoMinutes == "2026-10-12T09:00+04:00:30.250000")
    #expect(PlanTime(2026, 10, 12, 9, 0, zone: .fixed(-5 * 3_600_000_000 - 30 * 60_000_000)).isoMinutes == "2026-10-12T09:00-05:30")
    #expect(PlanTime(2026, 10, 12, 9, 0, zone: .fixed(-30_000_000)).isoMinutes == "2026-10-12T09:00-00:00:30")
    #expect(PlanTime(7, 1, 2, 3, 4, zone: .fixed(0)).isoMinutes == "0007-01-02T03:04+00:00")
}

// MARK: - robo plan (the CLI)

private let now = at("07:00")

private func asDate(_ t: PlanTime) -> Date { Date(timeIntervalSince1970: Double(t.instant) / 1e6) }

private func instant(_ iso: String) -> Date {
    let f = PyISO.datetime(iso)!
    let wall = PlanTime(f.year, f.month, f.day, f.hour, f.minute, f.second, f.micro, zone: .fixed(0)).wall
    return Date(timeIntervalSince1970: Double(wall - (f.tz ?? 0)) / 1e6)
}

/// Run `robo plan` with the given files (written to a fresh folder) and arguments.
private func run(_ argv: [String], tasks: String? = nil, busy: String? = nil, stdin: String = "", at: Date? = nil) -> PlanOutput {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("robo-plan-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var args = argv
    if let tasks {
        try! Data(tasks.utf8).write(to: dir.appendingPathComponent("t.json"))
        args = ["--tasks", dir.appendingPathComponent("t.json").path] + args
    }
    if let busy {
        try! Data(busy.utf8).write(to: dir.appendingPathComponent("b.json"))
        args += ["--busy", dir.appendingPathComponent("b.json").path]
    }
    let out = planMain(args, now: at ?? asDate(now), stdin: { Data(stdin.utf8) })
    return PlanOutput(status: out.status, stdout: out.stdout.replacingOccurrences(of: dir.path, with: "DIR"),
                      stderr: out.stderr.replacingOccurrences(of: dir.path, with: "DIR"))
}

private let good = #"[{"id": "a", "title": "A", "minutes": 30}]"#

@Test func cliPrintsBlocksAndUnscheduledAsJSON() {
    let tasks = #"[{"id": "r", "title": "Read ch.3", "minutes": 60, "priority": 0.8}, "#
        + #"{"id": "e", "title": "Essay", "minutes": 90, "deadline": "2026-10-12T10:00:00+04:00"}]"#
    // UTC "Z" and a naive time read in --tz: 08:00-09:00 Dubai.
    let busy = #"[{"start": "2026-10-12T04:00:00Z", "end": "2026-10-12T09:00"}]"#
    let out = run(["--start", "08:00", "--end", "12:00"], tasks: tasks, busy: busy)
    #expect(out.status == 0 && out.stderr == "")
    // exactly the bytes Python's print(json.dumps(...)) gave
    #expect(out.stdout == #"{"blocks": [{"title": "Read ch.3", "start": "2026-10-12T09:00+04:00", "end": "2026-10-12T10:00+04:00"}], "#
        + #""unscheduled": [{"id": "e", "title": "Essay", "minutes": 90}]}"# + "\n")
}

@Test func cliReadsTasksFromStdinAndBusyIsOptional() {
    let out = planMain(["--tasks", "-", "--day", "2026-10-13", "--tz", "UTC"], now: asDate(now), stdin: { Data(good.utf8) })
    #expect(out.status == 0)
    #expect(out.stdout == #"{"blocks": [{"title": "A", "start": "2026-10-13T08:00+00:00", "end": "2026-10-13T08:30+00:00"}], "unscheduled": []}"# + "\n")
}

private func expectOneLineError(_ out: PlanOutput, _ says: String, _ comment: Comment? = nil) {
    #expect(out.status == 2 && out.stdout == "", comment)
    #expect(out.stderr.hasPrefix("robo plan: ") && out.stderr.filter { $0 == "\n" }.count == 1 && out.stderr.contains(says), comment)
}

@Test func cliBadInputIsExit2WithOneLine() {
    let cases: [(tasks: String?, extra: [String], busy: String?, says: String)] = [
        (nil, [], nil, "cannot read"),
        ("{oops", [], nil, "invalid JSON"),
        (#"{"id": "a"}"#, [], nil, "list of objects"),
        (#"[{"id": "a", "title": "A"}]"#, [], nil, "tasks[0]: missing 'minutes'"),
        (#"[{"id": "a", "title": "A", "minutes": 0}]"#, [], nil, "tasks[0]: minutes"),
        (#"[{"id": "a", "title": "A", "minutes": 30, "deadline": "tomorrow"}]"#, [], nil, "tasks[0].deadline"),
        (#"[{"id": "a", "title": "A", "minutes": 30, "priority": 2}]"#, [], nil, "priority"),
        (String(good.dropLast()) + #", {"id": "a", "title": "B", "minutes": 5}]"#, [], nil, "duplicate id 'a'"),
        (good, [], #"[{"start": "2026-10-12T09:00", "end": "soon"}]"#, "busy[0].end"),
        (good, ["--tz", "Mars/Base"], nil, "--tz"),
        (good, ["--day", "12/10/2026"], nil, "--day"),
        (good, ["--start", "22:00", "--end", "08:00"], nil, "--end"),
    ]
    for c in cases {
        let out = c.tasks == nil
            ? run(["--tasks", "/nonexistent/robo-plan/tasks.json"] + c.extra)
            : run(c.extra, tasks: c.tasks, busy: c.busy)
        expectOneLineError(out, c.says, Comment(rawValue: c.says))
    }
}

@Test func cliUsageErrorsAreExit2WithOneLine() {
    expectOneLineError(planMain([], now: asDate(now)), "--tasks")
    expectOneLineError(planMain(["--tasks", "-", "--busy", "-"], now: asDate(now)), "stdin")
}

// MARK: - the flags, as argparse reads them

private let pythonHelp = """
    usage: robo plan [-h] --tasks FILE [--busy FILE] [--day DAY] [--start START]
                     [--end END] [--tz TZ]

    Plan a day of study blocks around busy time. Prints {"blocks": [{title, start,
    end}], "unscheduled": [{id, title, minutes}]}.

    options:
      -h, --help     show this help message and exit
      --tasks FILE   JSON list (or - for stdin): [{"id", "title", "minutes",
                     "deadline"?, "priority"? 0..1}]
      --busy FILE    JSON list (or -): [{"start", "end"}], ISO times
      --day DAY      YYYY-MM-DD (default: today)
      --start START  HH:MM (default 08:00)
      --end END      HH:MM (default 22:00)
      --tz TZ        time zone (default Asia/Dubai); also used for ISO times
                     without an offset

    """

@Test func flagsFollowArgparse() {
    func err(_ argv: [String], stdin: String = "") -> String { planMain(argv, now: asDate(now), stdin: { Data(stdin.utf8) }).stderr }
    // each line is what Python 3.14's argparse + robo plan printed
    #expect(err([]) == "robo plan: the following arguments are required: --tasks\n")
    #expect(err(["--tasks"]) == "robo plan: argument --tasks: expected one argument\n")
    #expect(err(["--tasks", "x", "--bogus"]) == "robo plan: unrecognized arguments: --bogus\n")
    #expect(err(["--tasks", "x", "extra"]) == "robo plan: unrecognized arguments: extra\n")
    #expect(err(["--t", "x"]) == "robo plan: ambiguous option: --t could match --tasks, --tz\n")
    #expect(err(["--ta", "/nonexistent/x"]) == "robo plan: cannot read /nonexistent/x: No such file or directory\n")  // a unique prefix
    #expect(err(["--tas=/nonexistent/x", "--tz"]) == "robo plan: argument --tz: expected one argument\n")
    #expect(err(["--tasks", "x", "--tz", "--day", "1"]) == "robo plan: argument --tz: expected one argument\n")
    #expect(err(["--tasks", "/nonexistent/x", "--tasks", "/nonexistent/y"]) == "robo plan: cannot read /nonexistent/y: No such file or directory\n")  // the last wins
    #expect(err(["--tasks", "x", "-5"]) == "robo plan: unrecognized arguments: -5\n")
    #expect(err(["--tasks", "-5"]) == "robo plan: cannot read -5: No such file or directory\n")  // a number is a value
    #expect(err(["--tasks", "-x"]) == "robo plan: argument --tasks: expected one argument\n")  // an option is not
    #expect(err(["--tasks", "a b"]) == "robo plan: cannot read a b: No such file or directory\n")
    #expect(err(["--tasks", "x", "--"]) == "robo plan: unrecognized arguments: --\n")
    #expect(err(["--tasks", "x", "--", "y"]) == "robo plan: unrecognized arguments: -- y\n")
    #expect(err(["--tasks", ""]) == "robo plan: cannot read : Is a directory\n")
    #expect(err(["--tasks", "/"]) == "robo plan: cannot read /: Is a directory\n")
    #expect(err(["-tasks", "x"]) == "robo plan: the following arguments are required: --tasks\n")  // missing wins over unrecognized
    #expect(err(["--b", "x"]) == "robo plan: the following arguments are required: --tasks\n")
    #expect(err(["--d"]) == "robo plan: argument --day: expected one argument\n")
    #expect(err(["--tasks", "x", "--s", "1"]) == "robo plan: --start: expected HH:MM, got '1'\n")  // --s is --start
    #expect(err(["--e", "x", "--tasks=z"]) == "robo plan: --end: expected HH:MM, got 'x'\n")
    #expect(err(["--tasks", "x", "--tz=A=B"]) == "robo plan: --tz: unknown time zone 'A=B'\n")
    #expect(err(["--tasks", "-"], stdin: "") == "robo plan: stdin: invalid JSON (Expecting value: line 1 column 1 (char 0))\n")
    for help in [["-h"], ["--help"], ["--tasks", "x", "-hx"], ["--he"]] {
        let out = planMain(help, now: asDate(now))
        #expect(out.status == 0 && out.stderr == "" && out.stdout == pythonHelp)
    }
    // --busy "" is no --busy; --day "" is today
    let tasks = run(["--busy", "", "--day", ""], tasks: good)
    #expect(tasks.status == 0 && tasks.stdout.contains("2026-10-12T08:00+04:00"))
}

// MARK: - Python parity: whole runs

struct Fixture: Sendable, CustomTestStringConvertible {
    let name: String, tasks: String
    var busy: String?
    let stdin: Bool
    let args: [String], now: String
    let status: Int32, out: String, err: String
    init(_ name: String, tasks: String, busy: String? = nil, stdin: Bool, args: [String], now: String,
         status: Int32, out: String, err: String) {
        (self.name, self.tasks, self.busy, self.stdin, self.args, self.now) = (name, tasks, busy, stdin, args, now)
        (self.status, self.out, self.err) = (status, out, err)
    }
    var testDescription: String { name }
}

@Test(arguments: fixtures)
func swiftRunsLikePython(_ f: Fixture) {
    // the flags and files of `robo plan`, run by Python 3.14 with --tz as given and `now` fixed; its stdout
    // and stderr (without the final newline) are in `out` and `err`
    let got = run(f.stdin ? ["--tasks", "-"] + f.args : f.args, tasks: f.stdin ? nil : f.tasks, busy: f.busy, stdin: f.tasks, at: instant(f.now))
    #expect(got.status == f.status)
    #expect(got.stdout == (f.out.isEmpty ? "" : f.out + "\n"))
    #expect(got.stderr == (f.err.isEmpty ? "" : f.err + "\n"))
}

@Test func idsThatAreCanonicallyEquivalentStayDifferent() {
    // Python compares str by code point: "\u{e9}" and "e\u{301}" are two ids (Swift's == would merge them)
    let tasks = "[{\"id\": \"\\u00e9\", \"title\": \"\\u00e9\", \"minutes\": 30}, {\"id\": \"e\\u0301\", \"title\": \"e\\u0301\", \"minutes\": 30}]"
    let out = run(["--day", "2026-10-12"], tasks: tasks)
    #expect(out.status == 0)
    // Python: the decomposed id sorts first ("e" < "\u{e9}")
    #expect(out.stdout == "{\"blocks\": [{\"title\": \"e\u{301}\", \"start\": \"2026-10-12T08:00+04:00\", \"end\": \"2026-10-12T08:30+04:00\"}, "
        + "{\"title\": \"\u{e9}\", \"start\": \"2026-10-12T08:40+04:00\", \"end\": \"2026-10-12T09:10+04:00\"}], \"unscheduled\": []}\n")
}

// MARK: - Python parity: fromisoformat

private func shown(_ f: PyISO.Fields) -> String {
    func z(_ n: Int, _ w: Int) -> String { String(repeating: "0", count: max(0, w - String(n).count)) + String(n) }
    return "\(z(f.year, 4))-\(z(f.month, 2))-\(z(f.day, 2))T\(z(f.hour, 2)):\(z(f.minute, 2)):\(z(f.second, 2)).\(z(f.micro, 6))" + (f.tz.map { "@\($0)" } ?? "")
}

@Test func datetimeFromISOMatchesPython() {
    // datetime.fromisoformat in Python 3.14; nil = ValueError. A time zone is "@" and microseconds east of UTC.
    let cases: [(String, String?)] = [
        ("2026-10-12", "2026-10-12T00:00:00.000000"),
        ("2026-10-12T09:00", "2026-10-12T09:00:00.000000"),
        ("2026-10-12 09:00:30", "2026-10-12T09:00:30.000000"),
        ("2026-10-12X09:00", "2026-10-12T09:00:00.000000"),
        ("2026-10-12é09:00", "2026-10-12T09:00:00.000000"),
        ("20261012T0900", "2026-10-12T09:00:00.000000"),
        ("2026-W42-1T09:00", "2026-10-12T09:00:00.000000"),
        ("2026W421T0900", "2026-10-12T09:00:00.000000"),
        ("2026-W42T09:00", "2026-10-12T09:00:00.000000"),
        ("2026W42 09:00", "2026-10-12T09:00:00.000000"),
        ("2026-10-12T09", "2026-10-12T09:00:00.000000"),
        ("2026-10-12T24:00", "2026-10-13T00:00:00.000000"),
        ("2026-12-31T24:00", "2027-01-01T00:00:00.000000"),
        ("2026-10-12T24:00:01", nil),
        ("2026-10-12T09:00:00.123456789Z", "2026-10-12T09:00:00.123456@0"),
        ("2026-10-12T09:00Z", "2026-10-12T09:00:00.000000@0"),
        ("2026-10-12T09:00z", nil),
        ("2026-10-12T09:00+04:00", "2026-10-12T09:00:00.000000@14400000000"),
        ("2026-10-12T09:00-05:30", "2026-10-12T09:00:00.000000@-19800000000"),
        ("2026-10-12T09:00+0400", "2026-10-12T09:00:00.000000@14400000000"),
        ("2026-10-12T09:00+04", "2026-10-12T09:00:00.000000@14400000000"),
        ("2026-10-12T09:00 +04:00", "2026-10-12T09:00:00.000000@14400000000"),
        ("2026-10-12T09:00:60", nil),
        ("2026-10-12T", nil),
        ("2026-10-12T ", nil),
        ("2026-10-12 ", nil),
        ("2026-10-1209:00", nil),
        ("2026-10-12T09:00-24:00", nil),
        ("2026-10-12T09:00+23:59", "2026-10-12T09:00:00.000000@86340000000"),
        ("2026-10-12T09:00+00:99", "2026-10-12T09:00:00.000000@5940000000"),
        ("0001-01-01T00:00+04:00", "0001-01-01T00:00:00.000000@14400000000"),
        ("9999-12-31T23:59:59.999999", "9999-12-31T23:59:59.999999"),
        ("9999-12-31T24:00", nil),
        ("2026-02-29T10:00", nil),
        ("2024-02-29T10:00", "2024-02-29T10:00:00.000000"),
        ("2026-10-12T9:00", nil),
        (" 2026-10-12", nil),
        ("2026-10-12\n", nil),
        ("2026-10-12T09:00,5", nil),
        ("2026-10-12T09:00:00,5", "2026-10-12T09:00:00.500000"),
        ("2026-10-12T09:00-00:00", "2026-10-12T09:00:00.000000@0"),
        ("2026-10-12T09:00:00.5+04:00:30.25", "2026-10-12T09:00:00.500000@14430250000"),
        ("2026-10-12T09:00+00:00:00.5", "2026-10-12T09:00:00.000000@500000"),  // 3.14.0 dropped the fraction and gave UTC
        ("2026-10-12T09:00-00:00:00.5", "2026-10-12T09:00:00.000000@-500000"),
        ("2026-10-12T09:00+00:00:01", "2026-10-12T09:00:00.000000@1000000"),
        ("2026-10-12T09:00+00:00:00.000001", "2026-10-12T09:00:00.000000@1"),
        ("2026-10-12T09:00+00:00:00.0", "2026-10-12T09:00:00.000000@0"),
        ("2026-10-12T09:00-23:59:59.999999", "2026-10-12T09:00:00.000000@-86399999999"),
        // a decimal mark right before the offset has no digits: 3.14.0 let it through, 3.14.7 does not
        ("2026-10-12T09:00.+04:00", nil),
        ("2026-10-12T09:00,+04:00", nil),
        ("2026-10-12T09:00,Z", nil),
        ("2026-10-12T09.+04:00", nil),
        ("2026-10-12T09:00:00.+04:00", nil),
        ("2026-10-12T09:00:00,-00:00", nil),
        ("2026-10-12T09:00.5.+04:00", nil),
        ("2026-10-12T09:00x+04:00", "2026-10-12T09:00:00.000000@14400000000"),  // any other stray character is skipped
        ("2026-10-12T09:00:+04:00", "2026-10-12T09:00:00.000000@14400000000"),
        ("2026-10-12T09:00:00.5+04:00", "2026-10-12T09:00:00.500000@14400000000"),
        ("2026-W53-1", "2026-12-28T00:00:00.000000"),
        ("2026-W00-1", nil),
        ("2026-W42-8", nil),
        ("2025-W53-7", nil),
        ("2026-10-00T24:00", "2026-10-01T00:00:00.000000"),
        ("20261012T090030", "2026-10-12T09:00:30.000000"),
        ("2026-10-12T09:00:30.", nil),
        ("2026-10-12T09:00:30.1234567x+04:00", "2026-10-12T09:00:30.123456@14400000000"),
        ("2026101234", nil),
        ("2026-10-12T0900", "2026-10-12T09:00:00.000000"),
        ("2026-10-12T09:0030", nil),
    ]
    for (input, expected) in cases { #expect(PyISO.datetime(input).map(shown) == expected, Comment(rawValue: input.debugDescription)) }
}

@Test func dateFromISOMatchesPython() {
    let cases: [(String, String?)] = [
        ("2026-10-12", "2026-10-12"), ("20261012", "2026-10-12"), ("2026-W42-1", "2026-10-12"), ("2026W421", "2026-10-12"),
        ("2026-W42", "2026-10-12"), ("2026W42", "2026-10-12"), ("2026-10-1", nil), ("2026-1012", nil), ("2026-10-12 ", nil),
        ("2026-W53-1", "2026-12-28"), ("2026-W00-1", nil), ("0000-01-01", nil), ("2026-02-30", nil),
        ("2026101234", "2026-10-12"),  // text after the day is not looked at
        ("١٢٣٤-10-12", nil),
    ]
    for (input, expected) in cases {
        let got = PyISO.date(input).map { String(format: "%04ld-%02ld-%02ld", $0.year, $0.month, $0.day) }
        #expect(got == expected, Comment(rawValue: input.debugDescription))
    }
}

@Test func timeFromISOMatchesPython() {
    // time.fromisoformat: microseconds since midnight; the offset is checked and then dropped
    let cases: [(String, Int?)] = [
        ("08:00", 28_800_000_000), ("8:00", nil), ("08", 28_800_000_000), ("0800", 28_800_000_000), ("08:00:30", 28_830_000_000),
        ("080030", 28_830_000_000), ("08:00:30.5", 28_830_500_000), ("08:00:30,5", 28_830_500_000), ("08:00:30.1234567", 28_830_123_456),
        ("T08:00", 28_800_000_000), ("08:00Z", 28_800_000_000), ("08:00+04:00", 28_800_000_000), ("24:00", 0), ("24:00:01", nil),
        ("08:00-04:00:30", 28_800_000_000), ("08:00+25:00", nil), ("08:00+24:00", nil), ("08:00:", nil), ("08:0", nil),
        ("08:00:30.", nil), ("08.5", nil), ("23:59:60", nil), ("08003012", 28_830_120_000),
        ("", nil), ("T", nil), ("TT08:00", nil),
        ("08:00:30.+04:00", nil), ("09:00.+04:00", nil), ("08.+04:00", nil), ("0800.Z", nil), ("08:00,Z", nil), ("08:00:30.-123456789", nil),
        ("08:00x+04:00", 28_800_000_000), ("08:00 +04:00", 28_800_000_000), ("08:00:+04:00", 28_800_000_000),
        ("08:00:30.5+04:00", 28_830_500_000), ("08:00:30x", nil),
    ]
    for (input, expected) in cases { #expect(PyISO.time(input) == expected, Comment(rawValue: input.debugDescription)) }
}

// MARK: - Python parity: json

@Test func jsonErrorsReadLikePythons() {
    // str(json.JSONDecodeError) for json.loads(text) in Python 3.14
    let cases: [(String, String)] = [
        ("", "Expecting value: line 1 column 1 (char 0)"),
        (" ", "Expecting value: line 1 column 2 (char 1)"),
        ("{", "Expecting property name enclosed in double quotes: line 1 column 2 (char 1)"),
        ("[1,", "Expecting value: line 1 column 4 (char 3)"),
        ("[1 2]", "Expecting ',' delimiter: line 1 column 4 (char 3)"),
        ("{\"a\" 1}", "Expecting ':' delimiter: line 1 column 6 (char 5)"),
        ("{\"a\":1,}", "Illegal trailing comma before end of object: line 1 column 7 (char 6)"),
        ("[1,]", "Illegal trailing comma before end of array: line 1 column 3 (char 2)"),
        ("{1:2}", "Expecting property name enclosed in double quotes: line 1 column 2 (char 1)"),
        ("\"abc", "Unterminated string starting at: line 1 column 1 (char 0)"),
        ("\"a\\x\"", "Invalid \\escape: line 1 column 3 (char 2)"),
        ("\"a\\u12\"", "Invalid \\uXXXX escape: line 1 column 4 (char 3)"),
        ("\"a\\u12G4\"", "Invalid \\uXXXX escape: line 1 column 4 (char 3)"),
        ("\"a\nb\"", "Invalid control character at: line 1 column 3 (char 2)"),
        ("nul", "Expecting value: line 1 column 1 (char 0)"),
        ("tru", "Expecting value: line 1 column 1 (char 0)"),
        ("-", "Expecting value: line 1 column 1 (char 0)"),
        ("01", "Extra data: line 1 column 2 (char 1)"),
        ("1.", "Extra data: line 1 column 2 (char 1)"),
        (".5", "Expecting value: line 1 column 1 (char 0)"),
        ("[1]x", "Extra data: line 1 column 4 (char 3)"),
        ("\u{feff}[1]", "Unexpected UTF-8 BOM (decode using utf-8-sig): line 1 column 1 (char 0)"),
        ("{\"a\":1 \"b\":2}", "Expecting ',' delimiter: line 1 column 8 (char 7)"),
        ("'a'", "Expecting value: line 1 column 1 (char 0)"),
        ("[1,2", "Expecting ',' delimiter: line 1 column 5 (char 4)"),
        ("{\"a\":", "Expecting value: line 1 column 6 (char 5)"),
        ("{\"a\"", "Expecting ':' delimiter: line 1 column 5 (char 4)"),
        ("[", "Expecting value: line 1 column 2 (char 1)"),
        ("{\"a\":1", "Expecting ',' delimiter: line 1 column 7 (char 6)"),
        ("{\"a\":1,", "Expecting property name enclosed in double quotes: line 1 column 8 (char 7)"),
        ("[1,\n  2,\n  oops]", "Expecting value: line 3 column 3 (char 11)"),
        ("{\n \"a\": 1,\n \"b\" 2\n}", "Expecting ':' delimiter: line 3 column 6 (char 16)"),
        ("```json\n[1]\n```", "Expecting value: line 1 column 1 (char 0)"),
        ("[{\"id\": \"a\", \"title\": \"A\", \"minutes\": 30},]", "Illegal trailing comma before end of array: line 1 column 42 (char 41)"),
        // a string that ends right after a \uXXXX escape is unterminated; one that ends inside it is a bad escape
        ("\"abc\\u0041", "Unterminated string starting at: line 1 column 1 (char 0)"),
        ("[\"\\ud83d\\ude00", "Unterminated string starting at: line 1 column 2 (char 1)"),
        ("{\"a\":\"\\u0041", "Unterminated string starting at: line 1 column 6 (char 5)"),
        ("\"\\u0041", "Unterminated string starting at: line 1 column 1 (char 0)"),
        ("\"\\u00e9\\u0041", "Unterminated string starting at: line 1 column 1 (char 0)"),
        ("\"\\ud83d\\ude00x", "Unterminated string starting at: line 1 column 1 (char 0)"),
        ("\"abc\\u004", "Invalid \\uXXXX escape: line 1 column 6 (char 5)"),
        ("\"\\ud83d\\ude0", "Invalid \\uXXXX escape: line 1 column 9 (char 8)"),
        ("1" + String(repeating: "0", count: 4301), "Exceeds the limit (4300 digits) for integer string conversion: value has 4302 digits; use sys.set_int_max_str_digits() to increase the limit"),
    ]
    for (text, message) in cases {
        do {
            _ = try PyJSON.parse(text)
            Issue.record("parsed: \(text.prefix(40).debugDescription)")
        } catch let e as PyJSONError {
            #expect(e.message == message, Comment(rawValue: text.prefix(40).debugDescription))
        } catch { Issue.record("\(error)") }
    }
    // a BOM is dropped from bytes (a file) but not from text (stdin), as in Python
    #expect((try? PyJSON.parse(utf8: Data([0xEF, 0xBB, 0xBF] + Array("[1]".utf8)))) != nil)
    #expect(throws: PyJSONError.self) { try PyJSON.parse(utf8: Data([0xFF, 0xFE])) }
}

@Test func jsonValuesPrintLikePython() throws {
    // repr, str, json.dumps and json.dumps(indent=2) of json.loads(text)
    let cases: [(String, String, String, String, String)] = [
        ("[1, 1.0, -0.0, 1e5, 1e16, 1e-5, 123456789012345678901234567890, true, null, NaN, -Infinity]",
         "[1, 1.0, -0.0, 100000.0, 1e+16, 1e-05, 123456789012345678901234567890, True, None, nan, -inf]",
         "[1, 1.0, -0.0, 100000.0, 1e+16, 1e-05, 123456789012345678901234567890, True, None, nan, -inf]",
         "[1, 1.0, -0.0, 100000.0, 1e+16, 1e-05, 123456789012345678901234567890, true, null, NaN, -Infinity]",
         "[\n  1,\n  1.0,\n  -0.0,\n  100000.0,\n  1e+16,\n  1e-05,\n  123456789012345678901234567890,\n  true,\n  null,\n  NaN,\n  -Infinity\n]"),
        ("{\"a\": 1, \"b\": [1, {\"c\": \"d\"}], \"a\": 3}", "{'a': 3, 'b': [1, {'c': 'd'}]}", "{'a': 3, 'b': [1, {'c': 'd'}]}",
         "{\"a\": 3, \"b\": [1, {\"c\": \"d\"}]}", "{\n  \"a\": 3,\n  \"b\": [\n    1,\n    {\n      \"c\": \"d\"\n    }\n  ]\n}"),
        ("\"it's\"", "\"it's\"", "it's", "\"it's\"", "\"it's\""),
        ("\"say \\\"hi\\\"\"", "'say \"hi\"'", "say \"hi\"", "\"say \\\"hi\\\"\"", "\"say \\\"hi\\\"\""),
        ("\"both ' and \\\"\"", "'both \\' and \"'", "both ' and \"", "\"both ' and \\\"\"", "\"both ' and \\\"\""),
        ("\"tab\\t nl\\n cr\\r bs\\\\ \\u0001 \\u007f \\u00a0 \\u200b \\u2028 é ☃ 💥 \\ud83d\\ude00\"",
         "'tab\\t nl\\n cr\\r bs\\\\ \\x01 \\x7f \\xa0 \\u200b \\u2028 é ☃ 💥 😀'",
         "tab\t nl\n cr\u{d} bs\\ \u{1} \u{7f} \u{a0} \u{200b} \u{2028} é ☃ 💥 😀",
         "\"tab\\t nl\\n cr\\r bs\\\\ \\u0001 \u{7f} \u{a0} \u{200b} \u{2028} é ☃ 💥 😀\"",
         "\"tab\\t nl\\n cr\\r bs\\\\ \\u0001 \u{7f} \u{a0} \u{200b} \u{2028} é ☃ 💥 😀\""),
        ("[]", "[]", "[]", "[]", "[]"),
        ("{}", "{}", "{}", "{}", "{}"),
        ("[[], {}, [[]]]", "[[], {}, [[]]]", "[[], {}, [[]]]", "[[], {}, [[]]]", "[\n  [],\n  {},\n  [\n    []\n  ]\n]"),
        ("{\"k\": {}}", "{'k': {}}", "{'k': {}}", "{\"k\": {}}", "{\n  \"k\": {}\n}"),
        ("0", "0", "0", "0", "0"),
        ("-0", "0", "0", "0", "0"),
        ("1.5e300", "1.5e+300", "1.5e+300", "1.5e+300", "1.5e+300"),
        ("5e-324", "5e-324", "5e-324", "5e-324", "5e-324"),
    ]
    for (text, repr, str, dumps, indented) in cases {
        let v = try PyJSON.parse(text)
        let c = Comment(rawValue: text.prefix(40).debugDescription)
        #expect(v.repr == repr, c)
        #expect(v.str == str, c)
        #expect(v.dumps() == dumps, c)
        #expect(v.dumps(indent: 2) == indented, c)
    }
}

@Test func pythonStrIsTheWordsInTitlesAndIds() {
    // what a non-string id or title becomes (str(...) in Python), through a whole run
    let out = run(["--day", "2026-10-12"], tasks: #"[{"id": 1, "title": null, "minutes": 30}, {"id": 1.0, "title": [1, "a'b", {"k": "v"}], "minutes": 30}]"#)
    #expect(out.stdout.contains(#""title": "None""#) && out.stdout.contains(#""title": "[1, \"a'b\", {'k': 'v'}]""#))
}

// MARK: - a task that never fits must not hang the packer

@Test(.timeLimit(.minutes(1)))
func aHugeTaskIsPackedInAFlash() {
    // 10^11 minutes is a billion blocks: Python builds them all (and does not come back in any useful time)
    let started = Date()
    let big = task("big", 100_000_000_000, priority: 0.9)
    let blocks = plan([big, task("small", 30)])
    #expect(blocks.filter { $0.taskId == "big" }.map(mins) == [90, 90, 90, 90, 90, 90, 90, 90])  // the day, filled
    #expect(left([big], blocks) == ["big:\(100_000_000_000 - 8 * 90)"])
    #expect(plan([big], ["00:00-23:59"]).isEmpty)  // no free time at all
    #expect(plan([task("e", Int.max)], ["00:00-23:59"]).isEmpty)
    #expect(plan([task("e", Int.max, deadline: "06:00")]).isEmpty)  // nothing can end by the deadline
    #expect(Date().timeIntervalSince(started) < 2, "took \(Date().timeIntervalSince(started)) s")
}

@Test(.timeLimit(.minutes(1)))
func aBillionMinutesTakeNoLongerThanAThousand() {
    let started = Date()
    let blocks = plan([task("a", 1_000_000_000, deadline: "12:00")])
    #expect(blocks.map(mins) == [90, 90])  // 08:00-09:30, 09:40-11:10; the next would end at 12:50, after the deadline
    #expect(Date().timeIntervalSince(started) < 1, "took \(Date().timeIntervalSince(started)) s")
}

// MARK: - Python parity: whole runs, listed

private let fixtures: [Fixture] = [
    Fixture("overlapping busy", tasks: #"[{"id": "read", "title": "Read ch.3", "minutes": 60, "priority": 0.8}, {"id": "essay", "title": "Essay", "minutes": 90}, {"id": "quiz", "title": "Quiz prep", "minutes": 45, "priority": 0.2}]"#, busy: #"[{"start": "2026-10-12T07:00", "end": "2026-10-12T08:30"}, {"start": "2026-10-12T10:00", "end": "2026-10-12T11:00"}, {"start": "2026-10-12T10:30", "end": "2026-10-12T12:00"}, {"start": "2026-10-12T12:00", "end": "2026-10-12T12:30"}, {"start": "2026-10-12T13:00", "end": "2026-10-12T13:00"}, {"start": "2026-10-12T21:00", "end": "2026-10-12T23:00"}]"#, stdin: false, args: ["--day", "2026-10-12"], now: "2026-10-12T07:00+04:00",
            status: 0, out: #"{"blocks": [{"title": "Read ch.3", "start": "2026-10-12T08:30+04:00", "end": "2026-10-12T09:30+04:00"}, {"title": "Essay", "start": "2026-10-12T12:30+04:00", "end": "2026-10-12T14:00+04:00"}, {"title": "Quiz prep", "start": "2026-10-12T14:10+04:00", "end": "2026-10-12T14:55+04:00"}], "unscheduled": []}"#, err: ""),
    Fixture("deadlines", tasks: #"[{"id": "essay", "title": "Essay", "minutes": 90, "deadline": "2026-10-12T12:00+04:00", "priority": 0.9}, {"id": "quiz", "title": "Quiz", "minutes": 30, "deadline": "2026-10-12T11:45"}, {"id": "late", "title": "Already late", "minutes": 30, "deadline": "2026-10-12T06:00"}, {"id": "open", "title": "Open task", "minutes": 60, "priority": 0.1}, {"id": "a", "title": "Split", "minutes": 200, "deadline": "2026-10-12T11:30"}]"#, busy: #"[{"start": "2026-10-12T08:00", "end": "2026-10-12T11:00"}]"#, stdin: false, args: ["--day", "2026-10-12"], now: "2026-10-12T07:00+04:00",
            status: 0, out: #"{"blocks": [{"title": "Quiz", "start": "2026-10-12T11:00+04:00", "end": "2026-10-12T11:30+04:00"}, {"title": "Open task", "start": "2026-10-12T11:40+04:00", "end": "2026-10-12T12:40+04:00"}], "unscheduled": [{"id": "essay", "title": "Essay", "minutes": 90}, {"id": "late", "title": "Already late", "minutes": 30}, {"id": "a", "title": "Split", "minutes": 200}]}"#, err: ""),
    Fixture("exam", tasks: #"[{"id": "exam", "title": "Revise for the exam", "minutes": 600, "deadline": "2026-10-15T09:00", "priority": 1.0}, {"id": "hw", "title": "Homework", "minutes": 120, "deadline": "2026-10-12T18:00", "priority": 0.7}]"#, stdin: false, args: ["--day", "2026-10-12", "--start", "09:00", "--end", "17:00"], now: "2026-10-12T07:00+04:00",
            status: 0, out: #"{"blocks": [{"title": "Revise for the exam", "start": "2026-10-12T09:00+04:00", "end": "2026-10-12T10:26+04:00"}, {"title": "Revise for the exam", "start": "2026-10-12T10:40+04:00", "end": "2026-10-12T12:06+04:00"}, {"title": "Revise for the exam", "start": "2026-10-12T12:20+04:00", "end": "2026-10-12T13:46+04:00"}, {"title": "Revise for the exam", "start": "2026-10-12T14:00+04:00", "end": "2026-10-12T15:26+04:00"}, {"title": "Homework", "start": "2026-10-12T15:40+04:00", "end": "2026-10-12T16:40+04:00"}], "unscheduled": [{"id": "exam", "title": "Revise for the exam", "minutes": 256}, {"id": "hw", "title": "Homework", "minutes": 60}]}"#, err: ""),
    Fixture("breaks", tasks: #"[{"id": "a", "title": "Long task", "minutes": 200}, {"id": "b", "title": "Short", "minutes": 30}]"#, stdin: false, args: ["--day", "2026-10-12"], now: "2026-10-12T07:00+04:00",
            status: 0, out: #"{"blocks": [{"title": "Long task", "start": "2026-10-12T08:00+04:00", "end": "2026-10-12T09:07+04:00"}, {"title": "Long task", "start": "2026-10-12T09:20+04:00", "end": "2026-10-12T10:27+04:00"}, {"title": "Long task", "start": "2026-10-12T10:40+04:00", "end": "2026-10-12T11:46+04:00"}, {"title": "Short", "start": "2026-10-12T12:00+04:00", "end": "2026-10-12T12:30+04:00"}], "unscheduled": []}"#, err: ""),
    Fixture("nothing fits", tasks: #"[{"id": "a", "title": "Big", "minutes": 120}, {"id": "b", "title": "Small", "minutes": 25}]"#, busy: #"[{"start": "2026-10-12T00:00", "end": "2026-10-13T00:00"}]"#, stdin: false, args: ["--day", "2026-10-12"], now: "2026-10-12T07:00+04:00",
            status: 0, out: #"{"blocks": [], "unscheduled": [{"id": "a", "title": "Big", "minutes": 120}, {"id": "b", "title": "Small", "minutes": 25}]}"#, err: ""),
    Fixture("empty day", tasks: #"[]"#, stdin: false, args: ["--day", "2026-10-12"], now: "2026-10-12T07:00+04:00",
            status: 0, out: #"{"blocks": [], "unscheduled": []}"#, err: ""),
    Fixture("mixed offsets", tasks: #"[{"id": "a", "title": "Alpha", "minutes": 60, "deadline": "2026-10-12T10:30:00.123456Z"}, {"id": "b", "title": "Beta", "minutes": 90, "priority": 0.9}]"#, busy: #"[{"start": "2026-10-12T04:00:00Z", "end": "2026-10-12 08:00:00+05:30"}, {"start": "20261012T1100", "end": "2026-10-12T11:45:30.5"}]"#, stdin: false, args: ["--day", "2026-10-12", "--end", "14:00"], now: "2026-10-12T07:00+04:00",
            status: 0, out: #"{"blocks": [{"title": "Beta", "start": "2026-10-12T08:00+04:00", "end": "2026-10-12T09:30+04:00"}, {"title": "Alpha", "start": "2026-10-12T09:40+04:00", "end": "2026-10-12T10:40+04:00"}], "unscheduled": []}"#, err: ""),
    Fixture("New York spring forward", tasks: #"[{"id": "a", "title": "Early", "minutes": 100}, {"id": "b", "title": "Second", "minutes": 60, "priority": 0.6}]"#, busy: #"[{"start": "2026-03-08T01:30", "end": "2026-03-08T03:15"}]"#, stdin: false, args: ["--tz", "America/New_York", "--day", "2026-03-08", "--start", "00:00", "--end", "06:00"], now: "2026-03-07T23:00-05:00",
            status: 0, out: #"{"blocks": [{"title": "Second", "start": "2026-03-08T00:00-05:00", "end": "2026-03-08T01:00-05:00"}, {"title": "Early", "start": "2026-03-08T03:15-04:00", "end": "2026-03-08T04:05-04:00"}, {"title": "Early", "start": "2026-03-08T04:15-04:00", "end": "2026-03-08T05:05-04:00"}], "unscheduled": []}"#, err: ""),
    Fixture("New York fall back", tasks: #"[{"id": "a", "title": "Night owl", "minutes": 150}, {"id": "b", "title": "Second", "minutes": 60}]"#, busy: #"[{"start": "2026-11-01T00:30", "end": "2026-11-01T00:50"}]"#, stdin: false, args: ["--tz", "America/New_York", "--day", "2026-11-01", "--start", "00:00", "--end", "04:00"], now: "2026-10-31T22:00-04:00",
            status: 0, out: #"{"blocks": [{"title": "Night owl", "start": "2026-11-01T00:50-04:00", "end": "2026-11-01T02:05-05:00"}, {"title": "Night owl", "start": "2026-11-01T02:15-05:00", "end": "2026-11-01T03:30-05:00"}], "unscheduled": [{"id": "b", "title": "Second", "minutes": 60}]}"#, err: ""),
    Fixture("New York fall back, now in the repeated hour", tasks: #"[{"id": "a", "title": "Night owl", "minutes": 150}]"#, stdin: false, args: ["--tz", "America/New_York", "--day", "2026-11-01", "--start", "00:00", "--end", "05:00"], now: "2026-11-01T01:20-05:00",
            status: 0, out: #"{"blocks": [{"title": "Night owl", "start": "2026-11-01T01:20-04:00", "end": "2026-11-01T02:35-05:00"}, {"title": "Night owl", "start": "2026-11-01T02:45-05:00", "end": "2026-11-01T04:00-05:00"}], "unscheduled": []}"#, err: ""),
    Fixture("ISO formats", tasks: #"[{"id": "w", "title": "Week date", "minutes": 30, "deadline": "2026-W42-1T17:00"}, {"id": "b", "title": "Basic", "minutes": 30, "deadline": "20261012T1700"}, {"id": "d", "title": "Date only", "minutes": 30, "deadline": "2026-10-12"}, {"id": "m", "title": "Midnight 24", "minutes": 30, "deadline": "2026-10-12T24:00"}, {"id": "f", "title": "Fraction", "minutes": 30, "deadline": "2026-10-12T12:00:00,5+0400"}, {"id": "h", "title": "Hour only", "minutes": 30, "deadline": "2026-10-12T15+04"}]"#, stdin: false, args: ["--day", "2026-10-12"], now: "2026-10-12T07:00+04:00",
            status: 0, out: #"{"blocks": [{"title": "Fraction", "start": "2026-10-12T08:00+04:00", "end": "2026-10-12T08:30+04:00"}, {"title": "Hour only", "start": "2026-10-12T08:40+04:00", "end": "2026-10-12T09:10+04:00"}, {"title": "Basic", "start": "2026-10-12T09:20+04:00", "end": "2026-10-12T09:50+04:00"}, {"title": "Week date", "start": "2026-10-12T10:00+04:00", "end": "2026-10-12T10:30+04:00"}, {"title": "Midnight 24", "start": "2026-10-12T10:40+04:00", "end": "2026-10-12T11:10+04:00"}], "unscheduled": [{"id": "d", "title": "Date only", "minutes": 30}]}"#, err: ""),
    Fixture("now rounds up", tasks: #"[{"id": "a", "title": "A", "minutes": 30}, {"id": "b", "title": "B", "minutes": 30}]"#, stdin: false, args: ["--day", "2026-10-12"], now: "2026-10-12T10:03:20+04:00",
            status: 0, out: #"{"blocks": [{"title": "A", "start": "2026-10-12T10:05+04:00", "end": "2026-10-12T10:35+04:00"}, {"title": "B", "start": "2026-10-12T10:45+04:00", "end": "2026-10-12T11:15+04:00"}], "unscheduled": []}"#, err: ""),
    Fixture("now after the day", tasks: #"[{"id": "a", "title": "A", "minutes": 30}]"#, stdin: false, args: ["--day", "2026-10-12"], now: "2026-10-12T23:30+04:00",
            status: 0, out: #"{"blocks": [], "unscheduled": [{"id": "a", "title": "A", "minutes": 30}]}"#, err: ""),
    Fixture("odd ids and titles", tasks: #"[{"id": 1, "title": null, "minutes": 30}, {"id": 2.5, "title": true, "minutes": 30}, {"id": [1, "a'b"], "title": {"k": "v\"x"}, "minutes": 30}, {"id": "é", "title": "é", "minutes": 30}, {"id": 10000000000000000000000000, "title": 1e+22, "minutes": 30}]"#, stdin: false, args: ["--day", "2026-10-12"], now: "2026-10-12T07:00+04:00",
            status: 0, out: #"{"blocks": [{"title": "None", "start": "2026-10-12T08:00+04:00", "end": "2026-10-12T08:30+04:00"}, {"title": "1e+22", "start": "2026-10-12T08:40+04:00", "end": "2026-10-12T09:10+04:00"}, {"title": "True", "start": "2026-10-12T09:20+04:00", "end": "2026-10-12T09:50+04:00"}, {"title": "{'k': 'v\"x'}", "start": "2026-10-12T10:00+04:00", "end": "2026-10-12T10:30+04:00"}, {"title": "é", "start": "2026-10-12T10:40+04:00", "end": "2026-10-12T11:10+04:00"}], "unscheduled": []}"#, err: ""),
    Fixture("duplicate empty ids pass", tasks: #"[{"id": "", "title": "One", "minutes": 30}, {"id": "", "title": "Two", "minutes": 30}]"#, stdin: false, args: ["--day", "2026-10-12"], now: "2026-10-12T07:00+04:00",
            status: 0, out: #"{"blocks": [{"title": "One", "start": "2026-10-12T08:00+04:00", "end": "2026-10-12T08:30+04:00"}, {"title": "Two", "start": "2026-10-12T08:40+04:00", "end": "2026-10-12T09:10+04:00"}], "unscheduled": []}"#, err: ""),
    Fixture("Kolkata", tasks: #"[{"id": "a", "title": "Chai", "minutes": 45, "deadline": "2026-10-12T11:00:00Z"}, {"id": "b", "title": "Dal", "minutes": 45}]"#, busy: #"[{"start": "2026-10-12T09:00+05:30", "end": "2026-10-12T09:50+05:30"}]"#, stdin: false, args: ["--tz", "Asia/Kolkata", "--day", "2026-10-12", "--start", "08:30"], now: "2026-10-12T03:00:00+00:00",
            status: 0, out: #"{"blocks": [{"title": "Chai", "start": "2026-10-12T09:50+05:30", "end": "2026-10-12T10:35+05:30"}, {"title": "Dal", "start": "2026-10-12T10:45+05:30", "end": "2026-10-12T11:30+05:30"}], "unscheduled": []}"#, err: ""),
    Fixture("Lord Howe DST", tasks: #"[{"id": "a", "title": "A", "minutes": 60}, {"id": "b", "title": "B", "minutes": 60}]"#, stdin: false, args: ["--tz", "Australia/Lord_Howe", "--day", "2026-04-05", "--start", "00:00", "--end", "04:00"], now: "2026-04-04T22:00+11:00",
            status: 0, out: #"{"blocks": [{"title": "A", "start": "2026-04-05T00:00+11:00", "end": "2026-04-05T01:00+11:00"}, {"title": "B", "start": "2026-04-05T01:10+11:00", "end": "2026-04-05T02:10+10:30"}], "unscheduled": []}"#, err: ""),
    Fixture("error: duplicate id", tasks: #"[{"id": "a", "title": "A", "minutes": 30}, {"id": "a", "title": "B", "minutes": 5}]"#, stdin: false, args: [], now: "2026-10-12T07:00+04:00",
            status: 2, out: "", err: #"robo plan: tasks: duplicate id 'a'"#),
    Fixture("error: bad deadline with quotes", tasks: #"[{"id": "a", "title": "A", "minutes": 30, "deadline": "it's \"soon\""}]"#, stdin: false, args: [], now: "2026-10-12T07:00+04:00",
            status: 2, out: "", err: #"robo plan: tasks[0].deadline: not an ISO datetime: 'it\'s "soon"'"#),
    Fixture("error: missing key", tasks: #"[{"id": "a", "title": "A"}]"#, stdin: false, args: [], now: "2026-10-12T07:00+04:00",
            status: 2, out: "", err: #"robo plan: tasks[0]: missing 'minutes'"#),
    Fixture("error: minutes 1.5", tasks: #"[{"id": "a", "title": "A", "minutes": 1.5}]"#, stdin: false, args: [], now: "2026-10-12T07:00+04:00",
            status: 2, out: "", err: #"robo plan: tasks[0]: minutes must be a positive whole number"#),
    Fixture("error: minutes and priority both wrong", tasks: #"[{"id": "a", "title": "A", "minutes": 0, "priority": "x"}]"#, stdin: false, args: [], now: "2026-10-12T07:00+04:00",
            status: 2, out: "", err: #"robo plan: tasks[0]: minutes must be a positive whole number"#),
    Fixture("error: busy start missing", tasks: #"[{"id": "a", "title": "A", "minutes": 30}]"#, busy: #"[{"end": "2026-10-12T10:00"}]"#, stdin: false, args: [], now: "2026-10-12T07:00+04:00",
            status: 2, out: "", err: #"robo plan: busy[0].start: not an ISO datetime: None"#),
    Fixture("error: busy not a list of objects", tasks: #"[{"id": "a", "title": "A", "minutes": 30}]"#, busy: #"[1]"#, stdin: false, args: [], now: "2026-10-12T07:00+04:00",
            status: 2, out: "", err: #"robo plan: busy: expected a JSON list of objects"#),
    Fixture("error: tasks invalid JSON, trailing comma", tasks: #"[{"id": "a", "title": "A", "minutes": 30},]"#, stdin: true, args: [], now: "2026-10-12T07:00+04:00",
            status: 2, out: "", err: #"robo plan: stdin: invalid JSON (Illegal trailing comma before end of array: line 1 column 42 (char 41))"#),
    Fixture("error: end before start", tasks: #"[{"id": "a", "title": "A", "minutes": 30}]"#, stdin: false, args: ["--start", "10:00", "--end", "09:59"], now: "2026-10-12T07:00+04:00",
            status: 2, out: "", err: #"robo plan: --end must be after --start"#),
    Fixture("error: bad day", tasks: #"[{"id": "a", "title": "A", "minutes": 30}]"#, stdin: false, args: ["--day", "2026-02-30"], now: "2026-10-12T07:00+04:00",
            status: 2, out: "", err: #"robo plan: --day: expected YYYY-MM-DD, got '2026-02-30'"#),
    Fixture("error: unknown zone", tasks: #"[{"id": "a", "title": "A", "minutes": 30}]"#, stdin: false, args: ["--tz", "Mars/Base"], now: "2026-10-12T07:00+04:00",
            status: 2, out: "", err: #"robo plan: --tz: unknown time zone 'Mars/Base'"#),
    Fixture("error: ambiguous flag", tasks: #"[{"id": "a", "title": "A", "minutes": 30}]"#, stdin: false, args: ["--t", "UTC"], now: "2026-10-12T07:00+04:00",
            status: 2, out: "", err: #"robo plan: ambiguous option: --t could match --tasks, --tz"#),
    Fixture("lower-case zone name (macOS file system)", tasks: #"[{"id": "a", "title": "A", "minutes": 30}]"#, stdin: false, args: ["--tz", "asia/dubai", "--day", "2026-10-12"], now: "2026-10-12T07:00+04:00",
            status: 0, out: #"{"blocks": [{"title": "A", "start": "2026-10-12T08:00+04:00", "end": "2026-10-12T08:30+04:00"}], "unscheduled": []}"#, err: ""),
    Fixture("huge minutes fill the day", tasks: #"[{"id": "big", "title": "Big", "minutes": 100000, "priority": 0.9}, {"id": "small", "title": "Small", "minutes": 30}]"#, stdin: false, args: ["--day", "2026-10-12"], now: "2026-10-12T07:00+04:00",
            status: 0, out: #"{"blocks": [{"title": "Big", "start": "2026-10-12T08:00+04:00", "end": "2026-10-12T09:30+04:00"}, {"title": "Big", "start": "2026-10-12T09:40+04:00", "end": "2026-10-12T11:10+04:00"}, {"title": "Big", "start": "2026-10-12T11:20+04:00", "end": "2026-10-12T12:50+04:00"}, {"title": "Big", "start": "2026-10-12T13:00+04:00", "end": "2026-10-12T14:30+04:00"}, {"title": "Big", "start": "2026-10-12T14:40+04:00", "end": "2026-10-12T16:10+04:00"}, {"title": "Big", "start": "2026-10-12T16:20+04:00", "end": "2026-10-12T17:50+04:00"}, {"title": "Big", "start": "2026-10-12T18:00+04:00", "end": "2026-10-12T19:30+04:00"}, {"title": "Big", "start": "2026-10-12T19:40+04:00", "end": "2026-10-12T21:10+04:00"}, {"title": "Small", "start": "2026-10-12T21:20+04:00", "end": "2026-10-12T21:50+04:00"}], "unscheduled": [{"id": "big", "title": "Big", "minutes": 99280}]}"#, err: ""),
    Fixture("huge minutes stop at the deadline", tasks: #"[{"id": "t", "title": "Thesis", "minutes": 3000000, "deadline": "2026-10-12T12:00"}, {"id": "u", "title": "Other", "minutes": 45}]"#, busy: #"[{"start": "2026-10-12T09:30", "end": "2026-10-12T10:00"}]"#, stdin: false, args: ["--day", "2026-10-12"], now: "2026-10-12T07:00+04:00",
            status: 0, out: #"{"blocks": [{"title": "Thesis", "start": "2026-10-12T08:00+04:00", "end": "2026-10-12T09:30+04:00"}, {"title": "Thesis", "start": "2026-10-12T10:00+04:00", "end": "2026-10-12T11:30+04:00"}, {"title": "Other", "start": "2026-10-12T11:40+04:00", "end": "2026-10-12T12:25+04:00"}], "unscheduled": [{"id": "t", "title": "Thesis", "minutes": 2999820}]}"#, err: ""),
    Fixture("huge minutes and no free time", tasks: #"[{"id": "t", "title": "Thesis", "minutes": 3000000}]"#, busy: #"[{"start": "2026-10-12T00:00", "end": "2026-10-13T00:00"}]"#, stdin: false, args: ["--day", "2026-10-12"], now: "2026-10-12T07:00+04:00",
            status: 0, out: #"{"blocks": [], "unscheduled": [{"id": "t", "title": "Thesis", "minutes": 3000000}]}"#, err: ""),
]
