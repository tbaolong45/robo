// Port of tests/test_activity.py (macOS cases; the GNOME D-Bus and recently-used.xbel tests have no
// counterpart), plus goldens: Python's own output for the same rows. Tests use temp directories and
// injected readers, never the real database, Brave profile or windows.
import Foundation
import SQLite3
import Testing
@testable import RoboSystem

private let DAY = 86400.0

/// Local time on 2026-10-`d`, like Python's `datetime(2026, 10, d, h, m).timestamp()`.
private func at(_ h: Int, _ m: Int, day d: Int = 11) -> Double {
    CalendarDay.local.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!.timeIntervalSince1970
}
private let NOW = at(12, 0)  // local noon

private func withTemp<T>(_ body: (URL) throws -> T) rethrows -> T {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("robo-test-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

private func mode(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)!.intValue & 0o7777
}

private func s(_ ts: Double, _ app: String = "code", _ title: String = "t", idle: Int = 0, locked: Bool = false,
               domains: [String] = [], files: [String] = []) -> ActivitySample {
    ActivitySample(ts: Int(ts), app: app, title: title, idleS: idle, locked: locked, domains: domains, files: files)
}

private func rows(_ store: ActivityStore, _ sql: String) throws -> [[SQLValue]] { try store.query(sql) }

private func listing(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

private struct Hiccup: Error {}

private final class Counter {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
    var value: Int { lock.withLock { n } }
}

// MARK: - store

@Test func storeSchemaAndPrivateModes() throws {
    try withTemp { dir in
        let db = dir.appendingPathComponent("robo/activity.db")
        let store = try ActivityStore(path: db)
        #expect(mode(db.deletingLastPathComponent()) == 0o700 && mode(db) == 0o600)
        var cols: [String: [String]] = [:]
        for t in ["minutes", "sites", "files"] {
            cols[t] = try rows(store, "PRAGMA table_info(\(t))").map { $0[1].text! }
        }
        #expect(cols == ["minutes": ["ts", "app", "title", "idle_s", "locked"],
                         "sites": ["ts", "domain"], "files": ["ts", "path"]])
        // The Python build creates the same tables, so the same file serves both.
        #expect(try rows(store, "SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name")
                == [["files_ts"], ["minutes_ts"], ["sites_ts"]])
    }
}

@Test func storeTightensLooseModes() throws {
    try withTemp { dir in
        let d = dir.appendingPathComponent("robo")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let db = d.appendingPathComponent("activity.db")
        FileManager.default.createFile(atPath: db.path, contents: nil, attributes: [.posixPermissions: 0o644])
        #expect(mode(d) == 0o755 && mode(db) == 0o644)
        _ = try ActivityStore(path: db)
        #expect(mode(d) == 0o700 && mode(db) == 0o600)
    }
}

@Test func addAndPurge() throws {
    try withTemp { dir in
        let store = try ActivityStore(path: dir.appendingPathComponent("a.db"))
        try store.add(s(NOW - 31 * DAY, domains: ["old.com"], files: ["/old"]))
        try store.add(s(NOW - DAY, domains: ["new.com", "new.com"], files: ["/new"]))
        try store.purge(now: NOW)
        #expect(try rows(store, "SELECT ts FROM minutes") == [[.int(Int64(NOW - DAY))]])
        #expect(try rows(store, "SELECT domain FROM sites") == [["new.com"], ["new.com"]])
        #expect(try rows(store, "SELECT path FROM files") == [["/new"]])
        try store.purge(now: NOW, days: 0)
        #expect(try rows(store, "SELECT count(*) FROM minutes") == [[0]])
    }
}

@Test func addStoresEveryColumnAsPythonDoes() throws {
    try withTemp { dir in
        let store = try ActivityStore(path: dir.appendingPathComponent("a.db"))
        try store.add(s(NOW, "Code", "x.py", idle: 7, locked: true))
        try store.add(s(NOW + 60, "", "", idle: 0, locked: false))
        #expect(try rows(store, "SELECT ts, app, title, idle_s, locked, typeof(ts), typeof(locked) FROM minutes ORDER BY ts")
                == [[.int(Int64(NOW)), "Code", "x.py", 7, 1, "integer", "integer"],
                    [.int(Int64(NOW + 60)), "", "", 0, 0, "integer", "integer"]])
    }
}

// MARK: - sample

@Test func sampleWithFakes() {
    var seen: [String] = []
    let got = ActivityLog.sample(now: NOW, since: NOW - 60, focus: { ("code", "x.py") }, idle: { 7 }, locked: { true },
                                 sites: { a, b in seen.append("s \(a) \(b)"); return ["a.com"] },
                                 files: { a, b in seen.append("f \(a) \(b)"); return ["/x"] })
    #expect(got == ActivitySample(ts: Int(NOW), app: "code", title: "x.py", idleS: 7, locked: true,
                                  domains: ["a.com"], files: ["/x"]))
    #expect(seen == ["s \(NOW - 60) \(NOW)", "f \(NOW - 60) \(NOW)"])
}

@Test func idleIsWholeSecondsAndNeverTraps() {
    func idleS(_ x: Double) -> Int {
        ActivityLog.sample(now: NOW, since: NOW, focus: { ("", "") }, idle: { x }, locked: { false },
                           sites: { _, _ in [] }, files: { _, _ in [] }).idleS
    }
    #expect(idleS(113.9) == 113)  // Python's int() truncates
    #expect(idleS(1e30) == .max && idleS(.infinity) == .max && idleS(.nan) == .max)
}

// MARK: - Brave history

/// A Chromium-shaped History file; `urls` is [(url, unix_time)].
private func makeHistory(_ path: URL, _ urls: [(String, Double)]) throws {
    let db = try SQLiteDB(path.path)
    try db.exec("CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT);"
                + "CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER, visit_time INT);")
    for (i, (url, t)) in urls.enumerated() {
        try db.run("INSERT INTO urls VALUES (?, ?, 'secret title')", [.int(Int64(i + 1)), .text(url)])
        try db.run("INSERT INTO visits(url, visit_time) VALUES (?, ?)", [.int(Int64(i + 1)), .int(ActivityLog.webkit(t))])
    }
}

private let braveVisits: [(String, Double)] = [
    ("https://user:pw@Moodle.Example.com:8443/course/view.php?id=5", NOW - 10),
    ("https://a.com?q=secret", NOW - 20),
    ("http://b.org#frag", NOW - 30),
    ("https://a.com/x", NOW - 40),
    ("chrome://settings/", NOW - 10),
    ("file:///home/u/private.pdf", NOW - 10),
    ("https://[::1]:8080/", NOW - 10),
    ("https://too-old.com/", NOW - 600),
    ("https://future.com/", NOW + 10),
]

@Test func sitesAreHostsOnlyInTheWindowAndTheCopyIsDeleted() throws {
    try withTemp { dir in
        let src = dir.appendingPathComponent("History")
        try makeHistory(src, braveVisits)
        let work = dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work.appendingPathComponent(".history-stale"), withIntermediateDirectories: true)
        try "left by a SIGKILL".write(to: work.appendingPathComponent(".history-stale/History"), atomically: true, encoding: .utf8)
        let got = ActivityLog.readSites(since: NOW - 60, now: NOW, history: src, workdir: work)
        #expect(got.sorted() == ["a.com", "a.com", "b.org", "moodle.example.com"])
        #expect(listing(work) == [])  // the copy and the stale one are gone
    }
}

@Test func theHistoryCopyIsPrivateAndOpenedReadOnly() throws {
    try withTemp { dir in
        let src = dir.appendingPathComponent("History")
        try makeHistory(src, braveVisits)
        let original = try Data(contentsOf: src)
        var seen: [(Int, Int, Bool, Bool)] = []
        let got = try ActivityLog.readHistory(src, since: NOW - 60, now: NOW, workdir: dir.appendingPathComponent("work")) { copy, db in
            seen.append((mode(copy), mode(copy.deletingLastPathComponent()), sqlite3_db_readonly(db.handle, "main") == 1,
                         (try? Data(contentsOf: copy)) == original))
        }
        #expect(got.count == 4)
        #expect(seen.count == 1 && seen[0] == (0o600, 0o700, true, true))
    }
}

@Test func hostnamesAreCleanedAndFiltered() throws {
    try withTemp { dir in
        let src = dir.appendingPathComponent("History")
        try makeHistory(src, [
            ("https://trailing.dot.com./x", NOW - 1), ("https://UPPER.Case.org/x", NOW - 2),
            ("https://under_score-dash.net/x", NOW - 3), ("https://two..dots.com/x", NOW - 4),
            ("https://spa ce.com/x", NOW - 5), ("https://\u{00E9}.com/x", NOW - 6),
            ("https://.lead.com/x", NOW - 7), ("https://10.0.0.1:80/x", NOW - 8), ("https:///nohost", NOW - 9),
        ])
        let got = ActivityLog.readSites(since: NOW - 60, now: NOW, history: src, workdir: dir.appendingPathComponent("w"))
        #expect(got.sorted() == ["10.0.0.1", "trailing.dot.com", "under_score-dash.net", "upper.case.org"])
    }
}

@Test func sitesCopyIsDeletedOnError() throws {
    try withTemp { dir in
        let src = dir.appendingPathComponent("History")
        try Data(String(repeating: "not a database", count: 100).utf8).write(to: src)
        let work = dir.appendingPathComponent("work")
        #expect(ActivityLog.readSites(since: NOW - 60, now: NOW, history: src, workdir: work) == [])
        #expect(listing(work) == [])
        #expect(ActivityLog.readSites(since: NOW - 60, now: NOW, history: dir.appendingPathComponent("missing"), workdir: work) == [])
    }
}

@Test func historyAuthorizerDeniesOtherColumnsAndWrites() throws {
    let db = try SQLiteDB(":memory:")
    try db.exec("CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT);")
    db.restrictToHistoryReads()
    try db.run("SELECT lower(url) FROM urls")
    for bad in ["SELECT title FROM urls", "INSERT INTO urls(url) VALUES ('x')", "DELETE FROM urls", "ATTACH ':memory:' AS x"] {
        #expect(throws: SQLiteError.self, "\(bad)") { try db.run(bad) }
    }
}

@Test func webkitTimeIsPythons() {
    // values from robo.activity._webkit
    #expect(ActivityLog.webkit(1760180400.5) == 13404654000500000)
    #expect(ActivityLog.webkit(0) == 11644473600000000)
    #expect(ActivityLog.webkit(-1.5) == 11644473598500000)
}

// MARK: - watcher

@Test func watcherPauseSkipsRecordingButPurges() throws {
    try withTemp { dir in
        let store = try ActivityStore(path: dir.appendingPathComponent("a.db"))
        try store.add(s(NOW - 40 * DAY))
        var calls: [Double] = []
        var times = [NOW - 120, NOW - 60, NOW].makeIterator()
        let w = ActivityWatcher(store: store, clock: { times.next()! }, sampler: { now, since in calls.append(since); return s(now) })
        w.pause(true)
        #expect(w.paused)
        w.tick()  // paused at NOW-60: nothing recorded, window moves on, old row purged
        #expect(try rows(store, "SELECT count(*) FROM minutes") == [[0]])
        w.pause(false)
        #expect(!w.paused)
        w.tick()
        #expect(calls == [NOW - 60])  // visits made while paused are never picked up
        #expect(try rows(store, "SELECT ts FROM minutes") == [[.int(Int64(NOW))]])
    }
}

@Test func aFailedSampleLeavesTheWindowOpen() throws {
    try withTemp { dir in
        let store = try ActivityStore(path: dir.appendingPathComponent("a.db"))
        var sinces: [Double] = []
        var times = [NOW - 120, NOW - 60, NOW].makeIterator()
        let w = ActivityWatcher(store: store, clock: { times.next()! }, sampler: { now, since in
            sinces.append(since)
            if sinces.count == 1 { throw Hiccup() }
            return s(now)
        })
        w.tick()
        w.tick()
        #expect(sinces == [NOW - 120, NOW - 120])
    }
}

@Test func watcherSurvivesBadSamples() throws {
    try withTemp { dir in
        let store = try ActivityStore(path: dir.appendingPathComponent("a.db"))
        let calls = Counter()
        let w = ActivityWatcher(store: store, interval: 0.01, sampler: { now, _ in
            let n = calls.next()
            if n % 2 == 1 { throw Hiccup() }  // a bus hiccup
            return s(now + Double(n))
        })
        w.start()
        let deadline = Date().addingTimeInterval(5)
        func count() -> Int { Int(try! rows(store, "SELECT count(*) FROM minutes")[0][0].int!) }
        while count() < 2 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        w.stop()
        #expect(count() >= 2)
        let after = calls.value
        Thread.sleep(forTimeInterval: 0.1)
        #expect(calls.value == after)  // nothing samples once stop() has returned
    }
}

@Test func watcherStartsOnceAndCanBeRestarted() throws {
    try withTemp { dir in
        let store = try ActivityStore(path: dir.appendingPathComponent("a.db"))
        let calls = Counter()
        let w = ActivityWatcher(store: store, interval: 0.01, sampler: { now, _ in _ = calls.next(); return s(now) })
        w.stop()  // harmless before start
        w.start()
        w.start()  // a second start is ignored; one stop() ends the watching
        Thread.sleep(forTimeInterval: 0.3)
        w.stop()
        let first = calls.value
        #expect(first > 0)
        Thread.sleep(forTimeInterval: 0.1)
        #expect(calls.value == first)
        w.start()
        Thread.sleep(forTimeInterval: 0.2)
        w.stop()
        #expect(calls.value > first)
    }
}

// MARK: - summary

private typealias Builder = (ActivityStore) throws -> Void

private func aggregates(_ store: ActivityStore) throws {
    for i in 0..<3 { try store.add(s(at(9, i), "brave-browser", "Moodle - Brave", domains: ["moodle.org", "moodle.org"])) }
    try store.add(s(at(10, 0), "code", "activity.py", files: ["/home/u/a.py"]))
    try store.add(s(at(10, 1), "code", "idle title", idle: 300))
    try store.add(s(at(10, 2), "code", "locked title", locked: true))
    try store.add(s(at(23, 30), "", ""))
    try store.add(s(at(9, 0) - DAY, "slack", "yesterday"))
}

private func compact(_ store: ActivityStore) throws {
    for i in 0..<300 {
        try store.add(s(at(8, 0) + 60 * Double(i), "app\(i % 40)", String(repeating: "T", count: 300) + "\(i)",
                        domains: ["site\(i).example.com"], files: ["/home/u/\(String(repeating: "d", count: 80))/\(i).txt"]))
    }
}

private func idleOnly(_ store: ActivityStore) throws {
    try store.add(s(at(9, 0, day: 10), "code", "away", idle: 900))
    try store.add(s(at(9, 1, day: 10), "code", "locked", locked: true))
}

/// Equal counts everywhere: what is cut at 12 apps, 10 windows, 15 sites and 12 files comes from first appearance.
private func ties(_ store: ActivityStore) throws {
    for i in 0..<40 {
        let n = (i * 7) % 16
        try store.add(s(at(12, 0) + 60 * Double(i), String(format: "app%02d", n), i % 5 == 0 ? "shared" : String(format: "t%02d", n)))
    }
    try store.add(s(at(14, 0), "code", "sites",
                    domains: (0..<20).map { String(format: "d%02d.example", $0) } + Array(repeating: "z.example", count: 3),
                    files: (0..<15).map { String(format: "/Users/u/f%02d.txt", $0) }))  // 15 files, one timestamp
    try store.add(s(at(14, 1), "code", "sites", files: ["/Users/u/late.txt", "/Users/u/f03.txt"]))
}

private let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"  // one grapheme, seven scalars

/// Python counts and cuts code points: combining marks, a ZWJ emoji, NFC against NFD, "~" folding quirks.
private func text(_ store: ActivityStore) throws {
    try store.add(s(at(15, 0), "Brave", String(repeating: "\u{65E5}\u{672C}\u{8A9E}", count: 20) + String(repeating: family, count: 3)))
    try store.add(s(at(15, 1), "Brave", "caf\u{E9}"))
    try store.add(s(at(15, 2), "Brave", "cafe\u{301}"))  // looks equal, differs in code points
    try store.add(s(at(15, 3), "\u{DC}n\u{EF}", String(repeating: "x", count: 69)))
    try store.add(s(at(15, 4), "\u{DC}n\u{EF}", String(repeating: "y", count: 70)))
    try store.add(s(at(15, 5), "\u{DC}n\u{EF}", String(repeating: "z", count: 71)))
    try store.add(s(at(15, 6), "code", "files", files: [
        "/Users/u/Documents/a.txt", "/Users/uxyz/b.txt", "/opt/other.txt", "/Users/u",
        "/Users/u/" + String(repeating: "d", count: 100) + "/f.txt",
        "/Users/u/" + String(repeating: "\u{E9}", count: 30) + String(repeating: "e\u{301}", count: 30) + family + "/tail.txt"]))
}

private func span(_ store: ActivityStore) throws {
    try store.add(s(at(23, 59, day: 8), "late", "night", idle: 500, domains: ["a.org"], files: ["/Users/u/x"]))
    try store.add(s(at(8, 5, day: 9), "code", "one"))
    try store.add(s(at(8, 6, day: 9), "code", "one"))
    try store.add(s(at(18, 0, day: 10), "Slack", "chat", domains: ["slack.com", "slack.com", "b.org"]))
    try store.add(s(at(0, 0, day: 11), "Slack", "midnight"))
    try store.add(s(at(23, 59, day: 11), "Slack", "last"))
    try store.add(s(at(0, 0, day: 12), "Slack", "next day"))
}

/// Over 2500 characters, so the cut by code point shows.
private func huge(_ store: ActivityStore) throws {
    for i in 0..<20 {
        try store.add(s(at(8, 0) + 60 * Double(i), "app\(i)",
                        String(format: "%02d ", i) + String(repeating: "title e\u{301}", count: 30) + family,
                        domains: Array(repeating: String(repeating: "long", count: 15) + String(format: "%02d.example.com", i), count: i % 3 + 1),
                        files: ["/Users/u/" + String(repeating: "dir", count: 30) + String(format: "/file%02d", i) + family + ".txt"]))
    }
}

private let oct11 = CalendarDay(year: 2026, month: 10, day: 11)!
private let cases: [(name: String, build: [Builder], day: CalendarDay, days: Int)] = [
    ("aggregates", [aggregates], oct11, 1),
    ("aggregates2", [aggregates], oct11, 2),
    ("compact", [compact], oct11, 1),
    ("empty", [], oct11, 1),
    ("idle_only", [idleOnly], CalendarDay(year: 2026, month: 10, day: 10)!, 1),
    ("idle_only_other_day", [idleOnly], oct11, 1),
    ("ties", [ties], oct11, 1),
    ("text", [text], oct11, 1),
    ("huge", [huge], oct11, 1),
    ("span3", [span], oct11, 3),
    ("span1_oct8", [span], CalendarDay(year: 2026, month: 10, day: 8)!, 1),
    ("span2_oct9", [span], CalendarDay(year: 2026, month: 10, day: 9)!, 2),
]

@Test func summaryAggregatesAndExcludesIdleAndLocked() throws {
    try withTemp { dir in
        let store = try ActivityStore(path: dir.appendingPathComponent("a.db"))
        try aggregates(store)
        let out = try ActivityLog.summary(store, day: oct11, home: "/Users/u")
        #expect(out.contains("brave-browser 3") && out.contains("code 1") && out.contains("(unknown) 1"))
        #expect(!out.contains("idle title") && !out.contains("locked title") && !out.contains("slack"))
        #expect(out.contains("3 min  brave-browser: Moodle - Brave"))
        #expect(out.contains("moodle.org 6") && out.contains("/home/u/a.py"))
        #expect(out.contains("09:00") && out.contains("23:30") && out.contains("5 active min"))
        #expect(try ActivityLog.summary(store, day: oct11, days: 2, home: "/Users/u").contains("slack 1"))
    }
}

@Test func summaryIsCompactAndHandlesEmpty() throws {
    try withTemp { dir in
        let store = try ActivityStore(path: dir.appendingPathComponent("a.db"))
        #expect(try ActivityLog.summary(store, day: oct11).contains("No activity"))
        try compact(store)
        #expect(try ActivityLog.summary(store, day: oct11).unicodeScalars.count <= 2500)
    }
}

@Test func aDayOfOnlyIdleMinutesSaysSoInsteadOfNothingRecorded() throws {
    try withTemp { dir in
        let store = try ActivityStore(path: dir.appendingPathComponent("a.db"))
        try idleOnly(store)
        let out = try ActivityLog.summary(store, day: CalendarDay(year: 2026, month: 10, day: 10)!)
        #expect(out.contains("No active time") && out.contains("2 min recorded") && out.contains("idle or locked"))
        #expect(try ActivityLog.summary(store, day: oct11).contains("No activity recorded"))  // a day with no rows
    }
}

@Test("summary equals Python's, line for line", arguments: cases.map(\.name))
func summaryMatchesPython(_ name: String) throws {
    let c = cases.first { $0.name == name }!
    try withTemp { dir in
        let store = try ActivityStore(path: dir.appendingPathComponent("a.db"))
        for b in c.build { try b(store) }
        let got = try ActivityLog.summary(store, day: c.day, days: c.days, home: "/Users/u")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let want = golden[name]!
        #expect(got.count == want.count, "\(name): \(got.count) lines, Python had \(want.count)")
        for (i, (g, w)) in zip(got, want).enumerated() where g.unicodeScalars.elementsEqual(w.unicodeScalars) == false {
            Issue.record("\(name) line \(i): got \(g.debugDescription), Python \(w.debugDescription)")
        }
    }
}

@Test func theStudyLedgerIsCreatedPrivateAndTightened() throws {
    try withTemp { dir in
        let path = dir.appendingPathComponent("robo/study.md")
        try ActivityLog.ensureLedger(at: path)
        #expect(try String(contentsOf: path, encoding: .utf8) == "# Study ledger\n\n## Goals\n\n## Exams\n\n## Results\n\n## Notes\n")
        #expect(mode(path) == 0o600 && mode(path.deletingLastPathComponent()) == 0o700)
        try "# Study ledger\n\n## Goals\n- mine\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o664], ofItemAtPath: path.path)
        try ActivityLog.ensureLedger(at: path)
        #expect(try String(contentsOf: path, encoding: .utf8).contains("- mine"))  // never overwritten
        #expect(mode(path) == 0o600)
    }
}

// MARK: - macOS readers

private func win(_ layer: Int, _ owner: String, _ name: String? = nil, alpha: Double = 1.0) -> [String: Any] {
    var w: [String: Any] = ["kCGWindowLayer": layer, "kCGWindowOwnerName": owner, "kCGWindowAlpha": alpha]
    if let name { w["kCGWindowName"] = name }
    return w
}

@Test func frontWindowIsTheFirstVisibleNormalWindow() {
    let wins = [win(3, "Python", "Robo"),  // robo itself, always on top
                win(25, "Control Centre"),
                win(0, "Ghost", "helper", alpha: 0.0),  // an invisible helper window
                win(0, "Code", "activity.py"),
                win(0, "Safari", "Moodle")]
    let got = ActivityLog.frontWindow(wins)
    #expect(got.app == "Code" && got.title == "activity.py")
}

@Test func frontWindowWithoutScreenRecordingHasNoTitle() {
    let a = ActivityLog.frontWindow([win(0, "Code")])
    #expect(a.app == "Code" && a.title == "")
    let b = ActivityLog.frontWindow([])
    #expect(b.app == "" && b.title == "")
}

@Test func macFilesAsksSpotlightForTheWindow() {
    var asked: [String] = []
    let out = "/Users/u/Notes.pdf\n/Users/u/Notes.pdf\n\n/Users/u/a.py\n"
    let got = ActivityLog.macFiles(since: NOW - 60, now: NOW, find: { asked.append($0); return out })
    #expect(got == ["/Users/u/Notes.pdf", "/Users/u/a.py"])
    #expect(asked == ["kMDItemLastUsedDate > $time.iso(\(ActivityLog.utc(NOW - 60))) && "
                      + "kMDItemLastUsedDate <= $time.iso(\(ActivityLog.utc(NOW)))"])
    #expect(ActivityLog.utc(0) == "1970-01-01T00:00:00Z")
}

@Test func macFilesIsEmptyWhenSpotlightIsOffOrSlow() {
    #expect(ActivityLog.macFiles(since: NOW - 60, now: NOW, find: { _ in throw Hiccup() }) == [])
}

@Test func macFilesSplitsLinesLikePythonsSplitlines() {
    // str.splitlines() also breaks on \r, \v, \f, \x1c-\x1e, \x85, U+2028 and U+2029 (checked against Python)
    let out = "/a\r\n/b\u{0B}/c\u{2028}/d\u{85}/e\u{1C}/f\n\n/a\r/g\u{0C}/h\u{1D}/i\u{1E}/j\u{2029}not a path"
    #expect(ActivityLog.macFiles(since: 0, now: 1, find: { _ in out })
            == ["/a", "/b", "/c", "/d", "/e", "/f", "/g", "/h", "/i", "/j"])
}

@Test func utcFormatsAndRoundsLikePython() {
    // values from robo.activity._utc; fromtimestamp rounds to microseconds first, which can carry a second
    #expect(ActivityLog.utc(1760180400.9999996) == "2025-10-11T11:00:01Z")
    #expect(ActivityLog.utc(1760180400.9999994) == "2025-10-11T11:00:00Z")
    #expect(ActivityLog.utc(-0.5) == "1969-12-31T23:59:59Z")
    #expect(ActivityLog.utc(-0.0000004) == "1970-01-01T00:00:00Z")
    #expect(ActivityLog.utc(1.5) == "1970-01-01T00:00:01Z" && ActivityLog.utc(2.5) == "1970-01-01T00:00:02Z")
}

// MARK: - calendar day and `robo activity` arguments

@Test func calendarDayParsesOnlyRealIsoDates() {
    #expect(CalendarDay(iso: "2026-10-11") == CalendarDay(year: 2026, month: 10, day: 11))
    #expect(CalendarDay(iso: "2024-02-29")?.iso == "2024-02-29")
    for bad in ["2026-02-29", "2026-02-30", "2026-13-01", "2026-00-10", "2026-10-00", "2026-1-1", "26-10-11", "20261011",
                "2026-10-11x", "", "0000-01-01", "+026-10-11", "2026-10-11 ", "\u{FF12}026-10-11"] {
        #expect(CalendarDay(iso: bad) == nil, "\(bad)")
    }
    #expect(CalendarDay(year: 2026, month: 10, day: 11)!.description == "2026-10-11")
}

@Test func calendarDayMovesAcrossMonthsAndYears() {
    func d(_ iso: String, _ n: Int) -> String { CalendarDay(iso: iso)!.adding(days: n).iso }
    #expect(d("2026-03-01", -1) == "2026-02-28" && d("2024-03-01", -1) == "2024-02-29")
    #expect(d("2026-12-31", 1) == "2027-01-01" && d("2026-01-01", -1) == "2025-12-31")
    #expect(d("2026-10-11", 0) == "2026-10-11" && d("2026-10-11", 3) == "2026-10-14")
}

@Test func calendarDayIsTheLocalDayOfADate() {
    #expect(CalendarDay(Date(timeIntervalSince1970: at(0, 0))) == oct11)  // local midnight
    #expect(CalendarDay(Date(timeIntervalSince1970: at(23, 59))) == oct11)
    #expect(oct11.start.timeIntervalSince1970 == at(0, 0))
}

// MARK: - days and dates out of range

// Python's summary() for these (day, days): the text, or the last line of the traceback `robo activity` prints
// (exit status 1). The ValueError cases are Python's `timestamp()` of the local midnight of 0001-01-01.
private let ranges: [(day: String, days: Int, result: String)] = [
    ("2026-10-11", Int.min, "OverflowError: Python int too large to convert to C int"),
    ("2026-10-11", Int.max, "OverflowError: Python int too large to convert to C int"),
    ("2026-10-11", Int.min + 1, "OverflowError: Python int too large to convert to C int"),
    ("2026-10-11", Int.max - 1, "OverflowError: Python int too large to convert to C int"),
    ("2026-10-11", 3652059, "OverflowError: date value out of range"),
    ("2026-10-11", 3652058, "OverflowError: date value out of range"),
    ("2026-10-11", 3652060, "OverflowError: date value out of range"),
    ("2026-10-11", -3000000, "OverflowError: date value out of range"),
    ("2026-10-11", 1000000000, "OverflowError: date value out of range"),
    ("2026-10-11", 1000000001, "OverflowError: days=1000000000; must have magnitude <= 999999999"),
    ("2026-10-11", 2147483648, "OverflowError: days=2147483647; must have magnitude <= 999999999"),
    ("2026-10-11", 2147483649, "OverflowError: Python int too large to convert to C int"),
    ("2026-10-11", -2147483647, "OverflowError: days=-2147483648; must have magnitude <= 999999999"),
    ("2026-10-11", -2147483648, "OverflowError: Python int too large to convert to C int"),
    ("2026-10-11", -2147483649, "OverflowError: Python int too large to convert to C int"),
    ("2026-10-11", 999999999, "OverflowError: date value out of range"),
    ("2026-10-11", 100000, "No activity recorded for 1752-12-27..2026-10-11."),
    ("2026-10-11", 738000, "No activity recorded for 0006-03-16..2026-10-11."),
    ("2026-10-11", 738800, "No activity recorded for 0004-01-06..2026-10-11."),
    ("2026-10-11", 739000, "No activity recorded for 0003-06-20..2026-10-11."),
    ("2026-10-11", -738000, "No activity recorded for 4047-05-10..2026-10-11."),
    ("2026-10-11", 0, "No activity recorded for 2026-10-12..2026-10-11."),
    ("2026-10-11", -1, "No activity recorded for 2026-10-13..2026-10-11."),
    ("2026-10-11", 1, "No activity recorded for 2026-10-11."),
    ("2026-10-11", 2, "No activity recorded for 2026-10-10..2026-10-11."),
    ("9999-12-31", 1, "OverflowError: date value out of range"),  // day + 1 is past year 9999
    ("9999-12-31", 0, "OverflowError: date value out of range"),
    ("9999-12-30", 1, "No activity recorded for 9999-12-30."),
    ("9999-12-30", 2, "No activity recorded for 9999-12-29..9999-12-30."),
    ("0001-01-02", 1, "No activity recorded for 0001-01-02."),
    ("0001-01-01", 2, "OverflowError: date value out of range"),
    ("0001-01-01", 1, "ValueError: year must be in 1..9999, not 0"),
    ("0001-01-02", 2, "ValueError: year must be in 1..9999, not 0"),
    ("0001-01-03", 3, "ValueError: year must be in 1..9999, not 0"),
    ("0001-01-03", 2, "No activity recorded for 0001-01-02..0001-01-03."),
    // Python's calendar is the proleptic Gregorian one: no skipped days in 1582, and 1500 is not a leap year
    ("1582-10-15", 2, "No activity recorded for 1582-10-14..1582-10-15."),
    ("1582-10-04", 2, "No activity recorded for 1582-10-03..1582-10-04."),
    ("1500-03-01", 2, "No activity recorded for 1500-02-28..1500-03-01."),
    ("1700-03-01", 3, "No activity recorded for 1700-02-27..1700-03-01."),
]

@Test("days out of range fail, and the rest span, like Python's summary()", arguments: Array(ranges.indices))
func rangesMatchPython(_ i: Int) throws {
    let r = ranges[i]
    try withTemp { dir in
        let store = try ActivityStore(path: dir.appendingPathComponent("a.db"))
        let got: String
        do { got = try ActivityLog.summary(store, day: CalendarDay(iso: r.day)!, days: r.days, home: "/Users/u") } catch { got = "\(error)" }
        #expect(got == r.result, "day \(r.day), days \(r.days)")
    }
}

@Test func everyDayHasALocalStart() {
    // `start` feeds the database query; it must give a date for any day --day can name, never trap
    var n = 0
    for y in stride(from: 1, through: 9999, by: 7) {
        for (m, d) in [(1, 1), (2, 28), (3, 1), (10, 4), (10, 15), (12, 31)] {
            if let day = CalendarDay(year: y, month: m, day: d) { _ = day.start; n += 1 }
        }
    }
    #expect(n > 8_000)
}

@Test func ordinalsAreDatetimesDate() {
    // (year, month, day, date.toordinal()) from Python
    for (y, m, d, o) in [(1, 1, 1, 1), (2026, 10, 11, 739900), (1582, 10, 15, 577736), (1582, 10, 4, 577725),
                         (1500, 3, 1, 547558), (1900, 3, 1, 693655), (2000, 2, 29, 730179), (2100, 3, 1, 766704),
                         (4000, 2, 29, 1460664), (9999, 12, 31, 3652059), (1752, 9, 14, 639797), (100, 2, 28, 36218),
                         (400, 12, 31, 146097)] {
        #expect(CalendarDay(year: y, month: m, day: d)!.ordinal == o, "\(y)-\(m)-\(d)")
        #expect(CalendarDay(ordinal: o).iso == String(format: "%04d-%02d-%02d", y, m, d), "ordinal \(o)")
    }
    // every day of years 1...9999: ordinal and back, one day after the other, in calendar order
    var bad = 0
    var prev = CalendarDay(ordinal: 1)
    for o in 2...3_652_059 {
        let day = CalendarDay(ordinal: o)
        let next = (prev.year, prev.month, prev.day)
        let isNext = (day.year, day.month, day.day) > next && day.ordinal == o && CalendarDay(year: day.year, month: day.month, day: day.day) == day
        if !isNext { bad += 1 }
        prev = day
    }
    #expect(bad == 0)
    #expect(CalendarDay(year: 1900, month: 2, day: 29) == nil && CalendarDay(year: 2000, month: 2, day: 29) != nil)
    #expect(CalendarDay(year: 1582, month: 10, day: 10) != nil)  // no gap: Python's calendar is proleptic
}

@Test func theCommandFailsWithPythonsLastTracebackLine() throws {
    try withTemp { dir in
        let store = try ActivityStore(path: dir.appendingPathComponent("a.db"))
        func run(_ a: [String]) -> (status: Int32, stdout: String, stderr: String) { activityReport(a, store: { store }) }
        let cInt = "OverflowError: Python int too large to convert to C int\n"
        // exit status 1 and nothing on stdout, like Python's traceback (checked by running `robo activity`)
        for a in [["--days", "-9223372036854775808"], ["--days", "9223372036854775807"], ["--days", "99999999999999999999"],
                  ["--days=-99999999999999999999"], ["--days", "2147483649"]] {
            let r = run(a)
            #expect(r.status == 1 && r.stdout == "" && r.stderr == cInt, "\(a)")
        }
        let date = "OverflowError: date value out of range\n"
        for a in [["--days", "3652059"], ["--day", "9999-12-31"], ["--day", "0001-01-01", "--days", "2"]] {
            let r = run(a)
            #expect(r.status == 1 && r.stdout == "" && r.stderr == date, "\(a)")
        }
        #expect(run(["--days", "1000000001"]).stderr == "OverflowError: days=1000000000; must have magnitude <= 999999999\n")
        let ok = run(["--day", "2026-10-11", "--days", "2"])
        #expect(ok.status == 0 && ok.stdout == "No activity recorded for 2026-10-10..2026-10-11.\n" && ok.stderr == "")
        #expect(run(["--days", "x"]).status == 2 && run(["--days", "-"]).status == 2 && run(["--days", "+"]).status == 2)
    }
}

@Test func activityArgumentsAreParsedLikeArgparse() {
    func parse(_ a: [String]) -> (CalendarDay?, Int)? { parseActivityArgs(a) }
    #expect(parse([])?.0 == nil && parse([])?.1 == 1)
    let a = parse(["activity", "--days", "3", "--day", "2026-10-11"])
    #expect(a?.0 == oct11 && a?.1 == 3)
    let b = parse(["--days=7", "activity", "--day=2026-10-09"])
    #expect(b?.0 == CalendarDay(year: 2026, month: 10, day: 9) && b?.1 == 7)
    #expect(parse(["--days", "-1"])?.1 == -1)
    // Python's int() has no limit, so these are accepted there (and then fail in summary with an OverflowError)
    #expect(parse(["--days", "99999999999999999999"])?.1 == Int.max && parse(["--days=+99999999999999999999"])?.1 == Int.max)
    #expect(parse(["--days", "-99999999999999999999"])?.1 == Int.min && parse(["--days", "9223372036854775808"])?.1 == Int.max)
    #expect(parse(["--days", "-9223372036854775808"])?.1 == Int.min && parse(["--days", "9223372036854775807"])?.1 == Int.max)
    #expect(parse(["--days", "+5"])?.1 == 5 && parse(["--days", "007"])?.1 == 7)
    for bad in [["--days"], ["--days", "x"], ["--days", "1.5"], ["--day", "2026-02-30"], ["--day"], ["--moodle", "x"], ["chat"], ["-h"]] {
        #expect(parse(bad) == nil, "\(bad)")
    }
}

// MARK: - Python's summary text for the scenarios above

// Generated by running robo.activity.ActivityStore and summary() on the same rows with HOME=/Users/u.
// One line per element; the trailing spaces ("Sites (visits): ") are Python's too.
private let golden: [String: [String]] = [
    "aggregates": [
        "Activity 2026-10-11: 5 active min (idle >= 120s and locked excluded), first 09:00, last 23:30",
        "Apps (active min): brave-browser 3, code 1, (unknown) 1",
        "Top windows:",
        "- 3 min  brave-browser: Moodle - Brave",
        "- 1 min  code: activity.py",
        "Sites (visits): moodle.org 6",
        "Files opened: /home/u/a.py",
    ],
    "aggregates2": [
        "Activity 2026-10-10..2026-10-11: 6 active min (idle >= 120s and locked excluded), first 10-10 09:00, last 10-11 23:30",
        "Apps (active min): brave-browser 3, slack 1, code 1, (unknown) 1",
        "Top windows:",
        "- 3 min  brave-browser: Moodle - Brave",
        "- 1 min  slack: yesterday",
        "- 1 min  code: activity.py",
        "Sites (visits): moodle.org 6",
        "Files opened: /home/u/a.py",
    ],
    "compact": [
        "Activity 2026-10-11: 300 active min (idle >= 120s and locked excluded), first 08:00, last 12:59",
        "Apps (active min): app0 8, app1 8, app2 8, app3 8, app4 8, app5 8, app6 8, app7 8, app8 8, app9 8, app10 8, app11 8",
        "Top windows:",
        "- 1 min  app0: TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT\u{2026}",
        "- 1 min  app1: TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT\u{2026}",
        "- 1 min  app2: TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT\u{2026}",
        "- 1 min  app3: TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT\u{2026}",
        "- 1 min  app4: TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT\u{2026}",
        "- 1 min  app5: TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT\u{2026}",
        "- 1 min  app6: TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT\u{2026}",
        "- 1 min  app7: TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT\u{2026}",
        "- 1 min  app8: TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT\u{2026}",
        "- 1 min  app9: TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT\u{2026}",
        "Sites (visits): site0.example.com 1, site1.example.com 1, site10.example.com 1, site100.example.com 1, site101.example.com 1, site102.example.com 1, site103.example.com 1, site104.example.com 1, site105.example.com 1, site106.example.com 1, site107.example.com 1, site108.example.com 1, site109.example.com 1, site11.example.com 1, site110.example.com 1",
        "Files opened: \u{2026}ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/299.txt, \u{2026}ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/298.txt, \u{2026}ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/297.txt, \u{2026}ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/296.txt, \u{2026}ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/295.txt, \u{2026}ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/294.txt, \u{2026}ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/293.txt, \u{2026}ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/292.txt, \u{2026}ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/291.txt, \u{2026}ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/290.txt, \u{2026}ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/289.txt, \u{2026}ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/288.txt",
    ],
    "empty": [
        "No activity recorded for 2026-10-11.",
    ],
    "idle_only": [
        "No active time for 2026-10-10: 2 min recorded, all idle or locked.",
    ],
    "idle_only_other_day": [
        "No activity recorded for 2026-10-11.",
    ],
    "ties": [
        "Activity 2026-10-11: 42 active min (idle >= 120s and locked excluded), first 12:00, last 14:01",
        "Apps (active min): app00 3, app07 3, app14 3, app05 3, app12 3, app03 3, app10 3, app01 3, app08 2, app15 2, app06 2, app13 2",
        "Top windows:",
        "- 3 min  app07: t07",
        "- 3 min  app14: t14",
        "- 3 min  app10: t10",
        "- 3 min  app01: t01",
        "- 2 min  app05: t05",
        "- 2 min  app12: t12",
        "- 2 min  app08: t08",
        "- 2 min  app13: t13",
        "- 2 min  app04: t04",
        "- 2 min  app11: t11",
        "Sites (visits): z.example 3, d00.example 1, d01.example 1, d02.example 1, d03.example 1, d04.example 1, d05.example 1, d06.example 1, d07.example 1, d08.example 1, d09.example 1, d10.example 1, d11.example 1, d12.example 1, d13.example 1",
        "Files opened: ~/late.txt, ~/f03.txt, ~/f14.txt, ~/f13.txt, ~/f12.txt, ~/f11.txt, ~/f10.txt, ~/f09.txt, ~/f08.txt, ~/f07.txt, ~/f06.txt, ~/f05.txt",
    ],
    "text": [
        "Activity 2026-10-11: 7 active min (idle >= 120s and locked excluded), first 15:00, last 15:06",
        "Apps (active min): Brave 3, \u{DC}n\u{EF} 3, code 1",
        "Top windows:",
        "- 1 min  Brave: \u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{65E5}\u{672C}\u{8A9E}\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}\u{1F468}\u{200D}\u{2026}",
        "- 1 min  Brave: caf\u{E9}",
        "- 1 min  Brave: cafe\u{301}",
        "- 1 min  \u{DC}n\u{EF}: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
        "- 1 min  \u{DC}n\u{EF}: yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy",
        "- 1 min  \u{DC}n\u{EF}: zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\u{2026}",
        "- 1 min  code: files",
        "Sites (visits): ",
        "Files opened: /opt/other.txt, ~xyz/b.txt, \u{2026}\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}/tail.txt, \u{2026}ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/f.txt, ~/Documents/a.txt, ~",
    ],
    "huge": [
        "Activity 2026-10-11: 20 active min (idle >= 120s and locked excluded), first 08:00, last 08:19",
        "Apps (active min): app0 1, app1 1, app2 1, app3 1, app4 1, app5 1, app6 1, app7 1, app8 1, app9 1, app10 1, app11 1",
        "Top windows:",
        "- 1 min  app0: 00 title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}ti\u{2026}",
        "- 1 min  app1: 01 title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}ti\u{2026}",
        "- 1 min  app2: 02 title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}ti\u{2026}",
        "- 1 min  app3: 03 title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}ti\u{2026}",
        "- 1 min  app4: 04 title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}ti\u{2026}",
        "- 1 min  app5: 05 title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}ti\u{2026}",
        "- 1 min  app6: 06 title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}ti\u{2026}",
        "- 1 min  app7: 07 title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}ti\u{2026}",
        "- 1 min  app8: 08 title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}ti\u{2026}",
        "- 1 min  app9: 09 title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}title e\u{301}ti\u{2026}",
        "Sites (visits): longlonglonglonglonglonglonglonglonglonglonglonglonglonglong02.example.com 3, longlonglonglonglonglonglonglonglonglonglonglonglonglonglong05.example.com 3, longlonglonglonglonglonglonglonglonglonglonglonglonglonglong08.example.com 3, longlonglonglonglonglonglonglonglonglonglonglonglonglonglong11.example.com 3, longlonglonglonglonglonglonglonglonglonglonglonglonglonglong14.example.com 3, longlonglonglonglonglonglonglonglonglonglonglonglonglonglong17.example.com 3, longlonglonglonglonglonglonglonglonglonglonglonglonglonglong01.example.com 2, longlonglonglonglonglonglonglonglonglonglonglonglonglonglong04.example.com 2, longlonglonglonglonglonglonglonglonglonglonglonglonglonglong07.example.com 2, longlonglonglonglonglonglonglonglonglonglonglonglonglonglong10.example.com 2, longlonglonglonglonglonglonglonglonglonglonglonglonglonglong13.example.com 2, longlonglonglonglonglonglonglonglonglonglonglonglonglonglong16.example.com 2, longlonglonglonglonglonglonglonglonglonglonglonglonglonglong19.example.com 2, longlonglonglonglonglonglonglonglonglonglonglonglonglonglong00.example.com 1, longlonglonglonglonglonglonglonglonglonglonglonglonglonglong03.example.com 1",
        "Files opened: \u{2026}dirdirdirdirdirdirdirdirdirdirdirdirdirdirdirdirdir/file19\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}.txt, \u{2026}dirdirdirdirdirdirdirdirdirdirdirdirdirdirdirdirdir/file18\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}.txt, \u{2026}dirdirdirdirdirdirdirdirdirdirdirdirdirdirdirdirdir/file17\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}.txt, \u{2026}",
    ],
    "span3": [
        "Activity 2026-10-09..2026-10-11: 5 active min (idle >= 120s and locked excluded), first 10-09 08:05, last 10-11 23:59",
        "Apps (active min): Slack 3, code 2",
        "Top windows:",
        "- 2 min  code: one",
        "- 1 min  Slack: chat",
        "- 1 min  Slack: midnight",
        "- 1 min  Slack: last",
        "Sites (visits): slack.com 2, b.org 1",
        "Files opened: ",
    ],
    "span1_oct8": [
        "Activity 2026-10-08: 0 active min (idle >= 120s and locked excluded)",
        "Apps (active min): ",
        "Top windows:",
        "Sites (visits): a.org 1",
        "Files opened: ~/x",
    ],
    "span2_oct9": [
        "Activity 2026-10-08..2026-10-09: 2 active min (idle >= 120s and locked excluded), first 10-09 08:05, last 10-09 08:06",
        "Apps (active min): code 2",
        "Top windows:",
        "- 2 min  code: one",
        "Sites (visits): a.org 1",
        "Files opened: ~/x",
    ],
]
