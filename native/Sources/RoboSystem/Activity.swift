// Local activity watcher: once a minute the focused app and window title, idle seconds, screen lock,
// Brave site hostnames and files opened. No screenshots, no keystrokes, no URL paths or queries.
// Kept only in ~/.local/share/robo/activity.db (dir 0700, file 0600) for 30 days. Port of
// src/robo/activity.py, macOS branch only (Quartz, Spotlight); the GNOME readers are not ported.
// The SQLite file is shared with the Python build: table and column names, the timestamp format and
// the `robo activity` text must stay identical.
import CoreGraphics
import Foundation
import SQLite3
import os

// MARK: - Calendar day

/// What Python raises for a number or date out of range; `description` is the last line of its traceback.
public struct ActivityRangeError: Error, CustomStringConvertible, Equatable {
    public let description: String
    static let cInt = ActivityRangeError(description: "OverflowError: Python int too large to convert to C int")
    static let date = ActivityRangeError(description: "OverflowError: date value out of range")
}

/// A date in the proleptic Gregorian calendar, years 1...9999, with no time or zone (Python's
/// `datetime.date`); midnight is local. Foundation's Gregorian calendar is Julian before 1582, so the date
/// arithmetic here is done on day numbers instead.
public struct CalendarDay: Equatable, CustomStringConvertible {
    public let year: Int, month: Int, day: Int

    /// Gregorian in the zone the Mac is in now (not `Calendar.current`: the user may prefer another calendar).
    static var local: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .autoupdatingCurrent
        return c
    }

    private static let maxOrdinal = 3_652_059  // 9999-12-31
    private static let monthDays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    private static func isLeap(_ y: Int) -> Bool { y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) }

    /// nil when the date does not exist (month 13, 30 February, year 0).
    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month),
              (1...(Self.monthDays[month - 1] + (month == 2 && Self.isLeap(year) ? 1 : 0))).contains(day) else { return nil }
        (self.year, self.month, self.day) = (year, month, day)
    }

    /// Python's `date.fromordinal`: 1 is 0001-01-01. Howard Hinnant's civil-from-days.
    init(ordinal: Int) {
        precondition((1...Self.maxOrdinal).contains(ordinal))
        let z = ordinal + 305  // days since 0000-03-01
        let era = z / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let m = mp < 10 ? mp + 3 : mp - 9
        (year, month, day) = (yoe + era * 400 + (m <= 2 ? 1 : 0), m, doy - (153 * mp + 2) / 5 + 1)
    }

    /// Python's `date.toordinal`.
    var ordinal: Int {
        let y = month <= 2 ? year - 1 : year
        let yoe = y % 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        return y / 400 * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 305
    }

    /// The day `date` falls on in local time; today by default.
    public init(_ date: Date = Date()) {
        let c = Self.local.dateComponents([.year, .month, .day], from: date)
        (year, month, day) = (c.year!, c.month!, c.day!)
    }

    /// "YYYY-MM-DD" only (Python also accepts "YYYYMMDD" and week dates); nil if it is not a real date.
    public init?(iso s: String) {
        let p = s.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              s.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) }),
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { iso }

    /// This day moved by `n` days (negative goes back); the result must stay within years 1...9999.
    public func adding(days n: Int) -> CalendarDay { try! shifted(timedelta: n, subtracting: false) }

    /// Python's `self ± timedelta(days=n)`, with its errors: `n` must fit a C int and be at most 999999999
    /// in magnitude, and the result a date in years 1...9999.
    func shifted(timedelta n: Int, subtracting: Bool) throws -> CalendarDay {
        if n > Int(Int32.max) || n < Int(Int32.min) { throw ActivityRangeError.cInt }
        if abs(n) > 999_999_999 {
            throw ActivityRangeError(description: "OverflowError: days=\(n); must have magnitude <= 999999999")
        }
        let o = ordinal + (subtracting ? -n : n)
        guard (1...Self.maxOrdinal).contains(o) else { throw ActivityRangeError.date }
        return CalendarDay(ordinal: o)
    }

    /// Local midnight at the start of this day. Before 1583 Foundation's calendar counts Julian days, so the
    /// instant is off by days there; no row can be that old, it only has to be an instant.
    var start: Date {
        let c = Self.local
        return c.date(from: DateComponents(year: year, month: month, day: day)).map { c.startOfDay(for: $0) }
            ?? Date(timeIntervalSince1970: Double(ordinal - 719_163) * 86_400)
    }
}

// MARK: - SQLite

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32, message: String
    var description: String { "sqlite \(code): \(message)" }
}

/// What one SQLite column holds; also a bound value (`1`, `1.5`, `"x"` and `.null` as literals).
enum SQLValue: Equatable, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral {
    case int(Int64), real(Double), text(String), null
    init(integerLiteral v: Int64) { self = .int(v) }
    init(floatLiteral v: Double) { self = .real(v) }
    init(stringLiteral v: String) { self = .text(v) }
    var text: String? { if case .text(let s) = self { return s } else { return nil } }
    var int: Int64? { if case .int(let n) = self { return n } else { return nil } }
}

/// One SQLite connection; closed when released.
final class SQLiteDB {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)  // SQLite copies bound text
    let handle: OpaquePointer

    init(_ path: String, readOnly: Bool = false) throws {
        var h: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let e = SQLiteError(code: rc, message: h.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open")
            sqlite3_close(h)
            throw e
        }
        handle = h
        sqlite3_busy_timeout(h, 10_000)  // Python's connect(timeout=10)
    }

    deinit { sqlite3_close(handle) }

    private var failure: SQLiteError {
        SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    /// One statement with its values bound; the rows it returns.
    @discardableResult
    func run(_ sql: String, _ args: [SQLValue] = []) throws -> [[SQLValue]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw failure }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(stmt, n, v)
            case .real(let v): sqlite3_bind_double(stmt, n, v)
            case .text(let v): sqlite3_bind_text(stmt, n, v, -1, Self.transient)
            case .null: sqlite3_bind_null(stmt, n)
            }
        }
        var rows: [[SQLValue]] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: rows.append((0..<sqlite3_column_count(stmt)).map { column(stmt, $0) })
            case SQLITE_DONE: return rows
            default: throw failure
            }
        }
    }

    private func column(_ stmt: OpaquePointer?, _ i: Int32) -> SQLValue {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: return .int(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(stmt, i))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(stmt, i)))
        default: return .null
        }
    }

    /// A script of statements: no values, no rows.
    func exec(_ script: String) throws {
        guard sqlite3_exec(handle, script, nil, nil, nil) == SQLITE_OK else { throw failure }
    }

    /// `body` between BEGIN and COMMIT, rolled back if it throws (Python's `with connection`).
    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Only the history query's SELECT, its four columns and its string functions; everything else is denied.
    func restrictToHistoryReads() {
        sqlite3_set_authorizer(handle, { _, action, a1, a2, _, _ in
            ActivityLog.historyAuthorizer(action, a1.map { String(cString: $0) }, a2.map { String(cString: $0) })
        }, nil)
    }
}

// MARK: - Store

/// One minute of activity: what was in front, how idle the user was, and what was read since the last.
public struct ActivitySample: Equatable {
    public var ts: Int
    public var app: String
    public var title: String
    public var idleS: Int
    public var locked: Bool
    public var domains: [String] = []
    public var files: [String] = []

    public init(ts: Int, app: String, title: String, idleS: Int, locked: Bool,
                domains: [String] = [], files: [String] = []) {
        (self.ts, self.app, self.title, self.idleS, self.locked) = (ts, app, title, idleS, locked)
        (self.domains, self.files) = (domains, files)
    }
}

/// The 0600 SQLite file. One short connection per call, so any thread may use it.
public final class ActivityStore {
    private static let schema = """
    CREATE TABLE IF NOT EXISTS minutes(ts INTEGER, app TEXT, title TEXT, idle_s INTEGER,
                                       locked INTEGER);
    CREATE TABLE IF NOT EXISTS sites(ts INTEGER, domain TEXT);
    CREATE TABLE IF NOT EXISTS files(ts INTEGER, path TEXT);
    CREATE INDEX IF NOT EXISTS minutes_ts ON minutes(ts);
    CREATE INDEX IF NOT EXISTS sites_ts ON sites(ts);
    CREATE INDEX IF NOT EXISTS files_ts ON files(ts);
    """
    public let path: URL

    /// Creates the directory (0700), the file (0600) and the tables if they are missing.
    public init(path: URL = ActivityLog.defaultDB) throws {
        self.path = path
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        try ActivityLog.makePrivateDir(dir)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)  // not ours to tighten (e.g. /tmp)
        close(open(path.path, O_RDWR | O_CREAT, 0o600))  // born 0600, never wider
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)  // and tightened if an earlier run left it looser
        try connect().exec(Self.schema)
    }

    func connect() throws -> SQLiteDB { try SQLiteDB(path.path) }

    func query(_ sql: String, _ args: [SQLValue] = []) throws -> [[SQLValue]] { try connect().run(sql, args) }

    /// Record one sample with its sites and files.
    public func add(_ x: ActivitySample) throws {
        let db = try connect()
        try db.transaction {
            try db.run("INSERT INTO minutes VALUES (?, ?, ?, ?, ?)",
                       [.int(Int64(x.ts)), .text(x.app), .text(x.title), .int(Int64(x.idleS)), .int(x.locked ? 1 : 0)])
            for d in x.domains { try db.run("INSERT INTO sites VALUES (?, ?)", [.int(Int64(x.ts)), .text(d)]) }
            for p in x.files { try db.run("INSERT INTO files VALUES (?, ?)", [.int(Int64(x.ts)), .text(p)]) }
        }
    }

    /// Delete rows older than `days` days before `now`.
    public func purge(now: Double, days: Int = 30) throws {
        let db = try connect()
        try db.transaction {
            for table in ["minutes", "sites", "files"] {
                try db.run("DELETE FROM \(table) WHERE ts < ?", [.int(Int64(now - Double(days) * 86400))])
            }
        }
    }
}

// MARK: - Readers and summary

/// Where the activity data lives, the macOS readers (Quartz, Spotlight, Brave's history) and the summary.
public enum ActivityLog {
    /// A minute this idle (or locked) is not active.
    public static let idleS = 120
    static let webkitEpoch = 11_644_473_600.0  // seconds from 1601-01-01 (Chromium's epoch) to 1970-01-01

    /// $HOME as Python's `Path.home()` sees it: the variable first, so a test can point it at a temp dir.
    public static var home: String {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()).path
    }
    public static var dataDir: URL { URL(fileURLWithPath: home + "/.local/share/robo") }
    public static var defaultDB: URL { dataDir.appendingPathComponent("activity.db") }
    /// Goals, exams and results the user tells robo (the study-ledger skill).
    public static var ledger: URL { dataDir.appendingPathComponent("study.md") }
    public static var braveHistory: URL {
        URL(fileURLWithPath: home + "/Library/Application Support/BraveSoftware/Brave-Browser/Default/History")
    }

    static func posixFailure() -> Error { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    /// `mkdir -p` where only the last directory is created 0700 (Python's `mkdir(mode=0o700, parents=True)`).
    static func makePrivateDir(_ dir: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) { return }
        try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(atPath: dir.path, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
    }

    /// Create the study ledger private (0600) before Hermes writes it; Hermes keeps the mode of a file it
    /// edits, while a file it creates would be readable by others. An existing ledger is never overwritten.
    public static func ensureLedger(at path: URL = ledger) throws {
        try makePrivateDir(path.deletingLastPathComponent())
        let fm = FileManager.default
        if !fm.fileExists(atPath: path.path) {
            let text = "# Study ledger\n\n## Goals\n\n## Exams\n\n## Results\n\n## Notes\n"
            fm.createFile(atPath: path.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    // MARK: Brave history: hostnames only

    // The host is cut out of `urls.url` by SQLite itself (scheme://[user@]host[:port][/?#...]), so a full URL
    // never reaches Swift.
    static let historySQL = """
    SELECT lower(CASE WHEN instr(h, ':') THEN substr(h, 1, instr(h, ':') - 1) ELSE h END) FROM (
     SELECT substr(hp, instr(hp, '@') + 1) AS h FROM (
      SELECT substr(r, 1, instr(r, '/') - 1) AS hp FROM (
       SELECT replace(replace(substr(u.url, instr(u.url, '://') + 3), '?', '/'), '#', '/') || '/'
              AS r
       FROM visits AS v JOIN urls AS u ON u.id = v.url
       WHERE v.visit_time > ? AND v.visit_time <= ?
         AND (u.url LIKE 'http://%' OR u.url LIKE 'https://%'))))
    """
    private static let historyReads = [("urls", "id"), ("urls", "url"), ("visits", "url"), ("visits", "visit_time")]
    private static let historyFuncs: Set = ["substr", "instr", "replace", "lower", "like"]

    /// SELECT of the four named columns with plain string functions; deny everything else.
    static func historyAuthorizer(_ action: Int32, _ arg1: String?, _ arg2: String?) -> Int32 {
        switch action {
        case SQLITE_SELECT: return SQLITE_OK
        case SQLITE_FUNCTION where historyFuncs.contains(arg2 ?? ""): return SQLITE_OK
        case SQLITE_READ where historyReads.contains(where: { $0.0 == arg1 && $0.1 == arg2 }): return SQLITE_OK
        default: return SQLITE_DENY
        }
    }

    static func webkit(_ unix: Double) -> Int64 { Int64((unix + webkitEpoch) * 1_000_000) }

    /// A private (0700) directory in `workdir` holding a private (0600) copy of the history file as `History`.
    static func copyHistory(_ history: URL, into workdir: URL) throws -> URL {
        try makePrivateDir(workdir)
        var template = Array((workdir.path + "/.history-XXXXXX").utf8CString)  // mkdtemp: mode 0700
        guard mkdtemp(&template) != nil else { throw posixFailure() }
        let dir = URL(fileURLWithPath: String(cString: template))
        do {
            let fd = open(dir.appendingPathComponent("History").path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw posixFailure() }
            let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let src = try FileHandle(forReadingFrom: history)
            defer { try? src.close(); try? out.close() }
            while let chunk = try src.read(upToCount: 1 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return dir
    }

    private static func isHost(_ h: String) -> Bool {
        h.unicodeScalars.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }
        }
    }

    /// `inspect` sees the private copy and its read-only connection just before the query runs.
    static func readHistory(_ history: URL, since: Double, now: Double, workdir: URL,
                            inspect: (URL, SQLiteDB) -> Void = { _, _ in }) throws -> [String] {
        let dir = try copyHistory(history, into: workdir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("History")
        let db = try SQLiteDB(copy.path, readOnly: true)
        db.restrictToHistoryReads()
        inspect(copy, db)
        let found = try db.run(historySQL, [.int(webkit(since)), .int(webkit(now))])
        return found.compactMap { $0[0].text }
            .map { h in String(h.unicodeScalars.reversed().drop(while: { $0 == "." }).reversed().map(Character.init)) }
            .filter(isHost)
    }

    /// One hostname per Brave visit in (since, now]; [] when unreadable.
    public static func readSites(since: Double, now: Double, history: URL = braveHistory,
                                 workdir: URL = dataDir) -> [String] {
        let fm = FileManager.default
        for stale in (try? fm.contentsOfDirectory(atPath: workdir.path)) ?? [] where stale.hasPrefix(".history-") {
            try? fm.removeItem(at: workdir.appendingPathComponent(stale))  // left by a SIGKILL or power cut
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: history.path, isDirectory: &isDir), !isDir.boolValue else { return [] }
        for _ in 0..<2 {  // a copy taken mid-write can be inconsistent: retry once
            if let hosts = try? readHistory(history, since: since, now: now, workdir: workdir) { return hosts }
        }
        return []
    }

    // MARK: macOS readers (Quartz, Spotlight): no extension needed

    /// (app, title) of the frontmost normal window in Quartz's front-to-back list. Robo's own always-on-top
    /// window and the menu bar sit above layer 0; the title needs Screen Recording.
    public static func frontWindow(_ windows: [[String: Any]]) -> (app: String, title: String) {
        for w in windows where (w["kCGWindowLayer"] as? Int) == 0 && ((w["kCGWindowAlpha"] as? Double) ?? 1) > 0 {
            return (w["kCGWindowOwnerName"] as? String ?? "", w["kCGWindowName"] as? String ?? "")
        }
        return ("", "")
    }

    public static func macFocus() -> (app: String, title: String) {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        return frontWindow(CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? [])
    }

    /// Seconds since the last keyboard, mouse or touch event of this login session.
    public static func macIdle() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    public static func macLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    /// Python's `datetime.fromtimestamp(t, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")`, including its rounding of the
    /// microseconds (half to even, which can carry into the next second).
    static func utc(_ t: Double) -> String {
        var sec = t.rounded(.towardZero)
        let us = ((t - sec) * 1e6).rounded(.toNearestOrEven)
        if us >= 1e6 { sec += 1 } else if us < 0 { sec -= 1 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: sec))
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    private struct SpotlightTimeout: Error {}

    /// Spotlight's answer to `query` in the home folder; throws if mdfind cannot run or takes over 20 s.
    public static func mdfind(_ query: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", home, query]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let killer = DispatchWorkItem { p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationReason == .exit else { throw SpotlightTimeout() }  // killed after 20 s
        return String(decoding: data, as: UTF8.self)
    }

    /// Files Spotlight saw opened in (since, now]; [] when Spotlight is off or slow.
    public static func macFiles(since: Double, now: Double, find: (String) throws -> String = mdfind) -> [String] {
        let query = "kMDItemLastUsedDate > $time.iso(\(utc(since))) && kMDItemLastUsedDate <= $time.iso(\(utc(now)))"
        guard let out = try? find(query) else { return [] }
        // Python's str.splitlines(): not only \n, and on code points (Swift's "\r\n" is one Character).
        let breaks = Set("\n\r\u{0B}\u{0C}\u{1C}\u{1D}\u{1E}\u{85}\u{2028}\u{2029}".unicodeScalars)
        var seen = Set<String>()
        return out.unicodeScalars.split(whereSeparator: { breaks.contains($0) })
            .map { String(String.UnicodeScalarView($0)) }
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    // MARK: Sampling

    /// What the watcher records: the readers' answers at `now`; sites and files since `since`.
    public static func sample(now: Double, since: Double,
                              focus: () -> (app: String, title: String) = macFocus,
                              idle: () -> Double = macIdle, locked: () -> Bool = macLocked,
                              sites: (Double, Double) -> [String] = { readSites(since: $0, now: $1) },
                              files: (Double, Double) -> [String] = { macFiles(since: $0, now: $1) }) -> ActivitySample {
        let (app, title) = focus()
        let idleS = Int(exactly: idle().rounded(.towardZero)) ?? .max  // no trap if the clock says "never"
        return ActivitySample(ts: Int(now), app: app, title: title, idleS: idleS, locked: locked(),
                              domains: sites(since, now), files: files(since, now))
    }

    // MARK: Summary for the LLM

    // Python's str indexes, slices and compares code points; Swift's String uses grapheme clusters and
    // canonical equivalence ("é" == "e\u{301}"). The summary works on arrays of scalars where that shows.
    private typealias Scalars = [Unicode.Scalar]

    private static func str<S: Sequence>(_ s: S) -> String where S.Element == Unicode.Scalar {
        String(String.UnicodeScalarView(s))
    }

    private static func clip(_ text: String, _ n: Int, tail: Bool = false) -> String {
        let u = Array(text.unicodeScalars)
        if u.count <= n { return text }
        return tail ? "…" + str(u.suffix(n - 1)) : str(u.prefix(n - 1)) + "…"
    }

    /// Python's `Counter.most_common(n)`: highest count first, equal counts in order of first appearance.
    private static func mostCommon<K: Hashable>(_ items: [K], _ n: Int) -> [(key: K, count: Int)] {
        var order: [K] = []
        var count: [K: Int] = [:]
        for k in items {
            if count[k] == nil { order.append(k) }
            count[k, default: 0] += 1
        }
        let ranked = order.enumerated().sorted { (count[$0.element]!, -$0.offset) > (count[$1.element]!, -$1.offset) }
        return ranked.prefix(n).map { (key: $0.element, count: count[$0.element]!) }
    }

    private struct AppTitle: Hashable { let app: Scalars, title: Scalars }

    /// Compact text: active minutes per app, top windows, top sites, files, first/last active. `home` is the
    /// folder shown as "~" in file paths.
    public static func summary(_ store: ActivityStore, day: CalendarDay? = nil, days: Int = 1,
                               home: String = ActivityLog.home) throws -> String {
        let day = day ?? CalendarDay()
        // Python: day - timedelta(days=days - 1), then the local midnights as timestamps, then day + 1; each can raise
        let (back, overflow) = days.subtractingReportingOverflow(1)
        if overflow { throw ActivityRangeError.cInt }
        let first = try day.shifted(timedelta: back, subtracting: true)
        let span = days == 1 ? day.iso : "\(first.iso)..\(day.iso)"
        // datetime.timestamp() of the local midnight of 0001-01-01 looks a day back, into year 0, in every zone
        if first.ordinal == 1 {
            throw ActivityRangeError(description: "ValueError: year must be in 1..9999, not 0")
        }
        let next = try day.shifted(timedelta: 1, subtracting: false)
        let range: [SQLValue] = [.real(first.start.timeIntervalSince1970), .real(next.start.timeIntervalSince1970)]
        let active = try store.query(
            "SELECT ts, app, title FROM minutes WHERE ts >= ? AND ts < ? AND idle_s < ? "
            + "AND locked = 0 ORDER BY ts", range + [.int(Int64(idleS))])
        let sites = try store.query(
            "SELECT domain, count(*) AS n FROM sites WHERE ts >= ? AND ts < ? GROUP BY domain "
            + "ORDER BY n DESC, domain LIMIT 15", range)
        let files = try store.query(
            "SELECT path, max(ts) AS t FROM files WHERE ts >= ? AND ts < ? GROUP BY path "
            + "ORDER BY t DESC LIMIT 12", range)
        let recorded = try store.query("SELECT count(*) FROM minutes WHERE ts >= ? AND ts < ?", range)[0][0].int ?? 0
        if active.isEmpty && sites.isEmpty && files.isEmpty {  // tell "watching but away" from "not watching"
            if recorded > 0 { return "No active time for \(span): \(recorded) min recorded, all idle or locked." }
            return "No activity recorded for \(span)."
        }
        let local = CalendarDay.local
        func clock(_ ts: Int64) -> String {
            let c = local.dateComponents([.month, .day, .hour, .minute], from: Date(timeIntervalSince1970: Double(ts)))
            if days == 1 { return String(format: "%02d:%02d", c.hour!, c.minute!) }
            return String(format: "%02d-%02d %02d:%02d", c.month!, c.day!, c.hour!, c.minute!)
        }
        let unknown = { (s: String?) in s.flatMap { $0.isEmpty ? nil : $0 } ?? "(unknown)" }
        let rows = active.map {
            (ts: $0[0].int ?? 0, app: Scalars(unknown($0[1].text).unicodeScalars), title: Scalars(($0[2].text ?? "").unicodeScalars))
        }
        let apps = mostCommon(rows.map(\.app), 12)
        let titles = mostCommon(rows.filter { !$0.title.isEmpty }.map { AppTitle(app: $0.app, title: $0.title) }, 10)
        var head = "Activity \(span): \(rows.count) active min (idle >= \(idleS)s and locked excluded)"
        if let a = rows.first, let z = rows.last { head += ", first \(clock(Int64(a.ts))), last \(clock(Int64(z.ts)))" }
        let lines = [head,
                     "Apps (active min): " + apps.map { "\(str($0.key)) \($0.count)" }.joined(separator: ", "),
                     "Top windows:"]
            + titles.map { "- \($0.count) min  \(str($0.key.app)): \(clip(str($0.key.title), 70))" }
            + ["Sites (visits): " + sites.map { "\($0[0].text ?? "") \($0[1].int ?? 0)" }.joined(separator: ", "),
               "Files opened: " + files.map { row -> String in
                   let p = row[0].text ?? ""
                   let under = p.unicodeScalars.starts(with: home.unicodeScalars)
                   return clip(under ? "~" + str(p.unicodeScalars.dropFirst(home.unicodeScalars.count)) : p, 70, tail: true)
               }.joined(separator: ", ")]
        return str(lines.joined(separator: "\n").unicodeScalars.prefix(2500))
    }
}

// MARK: - Watcher

/// Records one sample every `interval` s on its own queue; purges rows past 30 days.
/// Paused: nothing is recorded (and what happens meanwhile is never picked up), purge runs.
public final class ActivityWatcher {
    private static let log = Logger(subsystem: "ai.robo", category: "activity")
    let store: ActivityStore
    let interval: Double
    let clock: () -> Double
    let sampler: (Double, Double) throws -> ActivitySample
    private let lock = NSLock()  // `paused` and `since` are read on the sampler's queue, written from the UI's
    private var _paused = false
    private var since: Double
    private let queue = DispatchQueue(label: "ai.robo.activity", qos: .utility)
    private var timer: DispatchSourceTimer?

    public init(store: ActivityStore, interval: Double = 60,
                clock: @escaping () -> Double = { Date().timeIntervalSince1970 },
                sampler: @escaping (Double, Double) throws -> ActivitySample = { ActivityLog.sample(now: $0, since: $1) }) {
        (self.store, self.interval, self.clock, self.sampler) = (store, interval, clock, sampler)
        since = clock()
    }

    public var paused: Bool { lock.withLock { _paused } }

    public func pause(_ paused: Bool = true) { lock.withLock { _paused = paused } }

    /// One sample (unless paused) and one purge; what `start` runs every `interval` s.
    func tick() {
        let now = clock()
        do {
            if !paused { try store.add(sampler(now, lock.withLock { since })) }
            lock.withLock { since = now }  // a failed sample leaves the window open for the next one
        } catch {
            Self.log.warning("activity sample failed: \(error.localizedDescription)")
        }
        do { try store.purge(now: now) } catch { Self.log.warning("activity purge failed: \(error.localizedDescription)") }
    }

    public func start() {
        guard timer == nil else { return }
        lock.withLock { since = clock() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Stops the timer and waits (up to 5 s) for a sample in progress to finish.
    public func stop() {
        guard let t = timer else { return }
        timer = nil
        let done = DispatchSemaphore(value: 0)
        t.setCancelHandler { done.signal() }
        t.cancel()
        _ = done.wait(timeout: .now() + 5)
    }
}

// MARK: - `robo activity`

/// `robo activity [--days N] [--day YYYY-MM-DD]`: prints the summary of what the user did on this Mac
/// (read by the study skills). `args` are the arguments of the command, with or without "activity" itself;
/// returns the exit status: 2 for bad arguments (as argparse does), 1 if the database cannot be read or if
/// --day/--days are out of range (stderr then has the last line of the traceback Python would print).
public func runActivity(_ args: [String]) -> Int32 {
    let r = activityReport(args, store: { try ActivityStore() })
    FileHandle.standardOutput.write(Data(r.stdout.utf8))
    FileHandle.standardError.write(Data(r.stderr.utf8))
    return r.status
}

/// What `runActivity` writes and returns; the store is opened only once the arguments are good.
func activityReport(_ args: [String], store: () throws -> ActivityStore) -> (status: Int32, stdout: String, stderr: String) {
    guard let (day, days) = parseActivityArgs(args) else {
        return (2, "", "usage: robo activity [--days DAYS] [--day YYYY-MM-DD]\n")
    }
    do {
        return (0, try ActivityLog.summary(store(), day: day, days: days) + "\n", "")
    } catch let e as ActivityRangeError {
        return (1, "", "\(e)\n")
    } catch {
        return (1, "", "robo: \(error)\n")
    }
}

/// (last day, number of days) from `--days N` / `--days=N` / `--day D` / `--day=D`; nil if anything else is there.
func parseActivityArgs(_ args: [String]) -> (CalendarDay?, Int)? {
    var day: CalendarDay?
    var days = 1
    var rest = args[...]
    while let a = rest.popFirst() {
        let (name, inline) = a.firstIndex(of: "=").map { (String(a[..<$0]), String(a[a.index(after: $0)...])) } ?? (a, nil)
        switch name {
        case "activity": continue
        case "--days":
            // Python's int() has no limit: a longer number is accepted there and fails in summary with an
            // OverflowError, so it is clamped here (any clamped value is out of range there too)
            guard let v = inline ?? rest.popFirst(), v.utf8.dropFirst(v.hasPrefix("-") || v.hasPrefix("+") ? 1 : 0).allSatisfy({ (48...57).contains($0) }),
                  v.utf8.contains(where: { (48...57).contains($0) }) else { return nil }
            days = Int(v) ?? (v.hasPrefix("-") ? .min : .max)
        case "--day":
            guard let v = inline ?? rest.popFirst(), let d = CalendarDay(iso: v) else { return nil }
            day = d
        default: return nil
        }
    }
    return (day, days)
}
