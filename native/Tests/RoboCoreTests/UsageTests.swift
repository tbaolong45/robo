// The usage log: one JSON line per finished run in robo's data folder, today's sum, and the daily cap.
import Foundation
import Testing
@testable import RoboCore

private let VN = TimeZone(secondsFromGMT: 7 * 3600)!  // the user's zone: its date changes seven hours before UTC's
private let RECORD = UsageRecord(model: "claude-opus-4-5", input: 1200, output: 340, total: 1540, cacheRead: 9000, cacheWrite: 15)

/// 2026-10-19T00:00:00+07:00, the start of a day in `VN`.
private let MIDNIGHT = 1_792_342_800.0

/// A folder name that is not there; `made: true` makes it.
private func temp(made: Bool = true) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("robo-usage-\(UUID().uuidString)")
    if made { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    return url
}

private func mode(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1
}

@Suite struct UsageTests {
    @Test(arguments: [
        ([:], 0), (["ROBO_DAILY_TOKENS": ""], 0), (["ROBO_DAILY_TOKENS": "0"], 0), (["ROBO_DAILY_TOKENS": "lots"], 0),
        (["ROBO_DAILY_TOKENS": "-5"], 0), (["ROBO_DAILY_TOKENS": "500000"], 500_000),
    ] as [([String: String], Int)])
    func theCapComesFromTheEnvironmentAndZeroMeansOff(environment: [String: String], want: Int) {
        #expect(Usage.cap(environment) == want)
    }

    /// `robo setup` rewrites the login item byte for byte, so an environment variable put there would not survive it; the number in
    /// robo's data folder does.
    @Test func withoutTheEnvironmentTheCapComesFromAFileThatTheEnvironmentOverrides() throws {
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("daily_tokens")
        #expect(Usage.cap([:], file: file) == 0)  // no file
        try "6000000\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(Usage.cap([:], file: file) == 6_000_000)
        #expect(Usage.cap(["ROBO_DAILY_TOKENS": ""], file: file) == 6_000_000)  // an empty variable is no variable
        #expect(Usage.cap(["ROBO_DAILY_TOKENS": "500000"], file: file) == 500_000)  // the environment wins
        #expect(Usage.cap(["ROBO_DAILY_TOKENS": "0"], file: file) == 0)  // and can switch the cap off for a run
        for text in ["", "lots", "-5", "0", "6 000 000"] {
            try text.write(to: file, atomically: true, encoding: .utf8)
            #expect(Usage.cap([:], file: file) == 0, "\(text)")
        }
    }

    @Test func theStampIsIsoWithTheLocalOffsetSoItsFirstTenCharactersAreTheLocalDate() {
        #expect(Usage.stamp(MIDNIGHT, zone: VN) == "2026-10-19T00:00:00+07:00")
        #expect(Usage.stamp(MIDNIGHT - 1, zone: VN) == "2026-10-18T23:59:59+07:00")
        #expect(Usage.stamp(MIDNIGHT, zone: TimeZone(identifier: "UTC")!).prefix(10) == "2026-10-18")
    }

    @Test func aLineHoldsTheRunsNumbers() throws {
        let line = Usage.line(RECORD, status: "completed", seconds: 12.34, steps: 5, wall: MIDNIGHT + 3600, zone: VN)
        #expect(!line.contains("\n"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(json["ts"] as? String == "2026-10-19T01:00:00+07:00" && json["status"] as? String == "completed")
        #expect(json["model"] as? String == "claude-opus-4-5" && json["steps"] as? Int == 5 && json["seconds"] as? Double == 12.3)
        #expect(json["input"] as? Int == 1200 && json["output"] as? Int == 340 && json["total"] as? Int == 1540)
        #expect(json["cacheRead"] as? Int == 9000 && json["cacheWrite"] as? Int == 15)
        #expect(Set(json.keys) == ["ts", "seconds", "steps", "model", "input", "output", "total", "cacheRead", "cacheWrite", "status"])
    }

    @Test func aRunWithoutARecordLogsZeroTokens() throws {
        let line = Usage.line(nil, status: "cancelled", seconds: 2, steps: 0, wall: MIDNIGHT, zone: VN)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(json["status"] as? String == "cancelled" && json["total"] as? Int == 0 && json["model"] as? String == "")
    }

    @Test func theLogIsMadeLazilyWithPrivateModesAndGrowsByOneLinePerRun() throws {
        let home = temp()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent("data")  // not there yet
        let file = dir.appendingPathComponent("usage.jsonl")
        Usage.append("one", to: file)
        Usage.append("two", to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "one\ntwo\n")
        #expect(mode(dir) == 0o700 && mode(file) == 0o600)
    }

    @Test func aDeletedParentFolderIsNotRemade() {
        let home = temp(made: false)
        Usage.append("one", to: home.appendingPathComponent("data/usage.jsonl"))
        #expect(!FileManager.default.fileExists(atPath: home.path))
    }

    @Test func todaysTokensStopAtTheLocalMidnight() {
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("usage.jsonl")
        func log(_ wall: Double, _ total: Int, _ status: String = "completed") {
            Usage.append(Usage.line(UsageRecord(total: total), status: status, seconds: 1, steps: 0, wall: wall, zone: VN), to: file)
        }
        log(MIDNIGHT - 1, 100)  // the evening before
        log(MIDNIGHT, 7)
        log(MIDNIGHT + 12 * 3600, 30)
        log(MIDNIGHT + 13 * 3600, 0, "failed")  // a failed run counts nothing
        log(MIDNIGHT + 86_400, 1000)  // tomorrow
        #expect(Usage.todayTokens(file: file, now: MIDNIGHT + 13 * 3600, zone: VN) == 37)
        #expect(Usage.todayTokens(file: file, now: MIDNIGHT - 60, zone: VN) == 100)
        #expect(Usage.todayTokens(file: file, now: MIDNIGHT + 86_400 + 60, zone: VN) == 1000)
        #expect(Usage.todayTokens(file: file, now: MIDNIGHT + 3 * 86_400, zone: VN) == 0)
    }

    @Test func aMissingFileAndBadLinesCountNothing() throws {
        #expect(Usage.todayTokens(file: URL(fileURLWithPath: "/nonexistent/usage.jsonl"), now: MIDNIGHT, zone: VN) == 0)
        let dir = temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("usage.jsonl")
        Usage.append("not json", to: file)
        Usage.append(#"{"ts": "2026-10-19T01:00:00+07:00"}"#, to: file)  // no total
        Usage.append(Usage.line(UsageRecord(total: 5), status: "completed", seconds: 1, steps: 0, wall: MIDNIGHT + 60, zone: VN), to: file)
        #expect(Usage.todayTokens(file: file, now: MIDNIGHT + 120, zone: VN) == 5)
    }
}
