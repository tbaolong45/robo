// What a run cost, and a daily cap on it. Hermes reports the tokens of a run that completed (in its
// `run.completed` event; failed and cancelled runs carry none), robo logs one JSON line per finished run
// in `usage.jsonl` of its data folder, and a cap in ROBO_DAILY_TOKENS stops new runs once today's tokens reach it.
import Foundation

/// The tokens of one completed run as Hermes counted them, and the model that served it.
public struct UsageRecord: Equatable, Sendable {
    public var model: String
    public var input: Int, output: Int, total: Int, cacheRead: Int, cacheWrite: Int

    public init(model: String = "", input: Int = 0, output: Int = 0, total: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        (self.model, self.input, self.output, self.total, self.cacheRead, self.cacheWrite) = (model, input, output, total, cacheRead, cacheWrite)
    }
}

public enum Usage {
    /// The daily cap in tokens: ROBO_DAILY_TOKENS when it is set (and not empty), else the number in `file` (`daily_tokens` in robo's
    /// data folder, which survives `robo setup`: that rewrites the login item, so a variable put there would be lost); unset, 0 or not
    /// a number: no cap.
    public static func cap(_ environment: [String: String], file: URL? = nil) -> Int {
        var text = environment["ROBO_DAILY_TOKENS"] ?? ""
        if text.isEmpty, let file { text = (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
        return max(0, Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }

    /// Wall time as ISO 8601 with the zone's offset ("2026-10-19T14:03:22+07:00"), as robo-guard stamps its receipts:
    /// the first ten characters are the local date.
    public static func stamp(_ wall: Double, zone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        return formatter.string(from: Date(timeIntervalSince1970: wall))
    }

    /// One log line (JSON, no newline) for a run that ended `status`, after `seconds` and `steps` tool calls.
    /// Without a record (the run failed or was cancelled: Hermes counted nothing) the tokens are 0.
    public static func line(_ record: UsageRecord?, status: String, seconds: Double, steps: Int, wall: Double,
                            zone: TimeZone = .current) -> String {
        let r = record ?? UsageRecord()
        let row: [String: Any] = [
            "ts": stamp(wall, zone: zone), "seconds": (seconds * 10).rounded() / 10, "steps": steps, "model": r.model,
            "input": r.input, "output": r.output, "total": r.total, "cacheRead": r.cacheRead, "cacheWrite": r.cacheWrite,
            "status": status,
        ]
        let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Append `line` to `file`, making its folder (0700, one level: robo's data folder sits in the user's ~/.local/share, and a
    /// parent that is gone, such as a test's deleted home, is not remade) and the file (0600) when missing. The log is best
    /// effort: a failed write must never fail the run, so errors are dropped.
    public static func append(_ line: String, to file: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: false,
                                attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    /// The tokens logged today (`zone`'s date at `now`); 0 for a missing file. Reads the whole file: a line per run is small.
    public static func todayTokens(file: URL, now: Double, zone: TimeZone = .current) -> Int {
        struct Row: Decodable { var ts: String, total: Int }
        guard let data = try? Data(contentsOf: file) else { return 0 }
        let day = stamp(now, zone: zone).prefix(10)
        return data.split(separator: UInt8(ascii: "\n")).reduce(0) { sum, line in
            guard let row = try? JSONDecoder().decode(Row.self, from: Data(line)), row.ts.hasPrefix(day) else { return sum }
            return sum + row.total
        }
    }
}
