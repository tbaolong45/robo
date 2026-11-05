// `robo setup`, for robo's own agent: a temp dir stands in
// for the home, so nothing real is touched (no ~/.local/share/robo, no LaunchAgent, no agent is started).
import Foundation
import Testing
@testable import RoboSystem

private let fm = FileManager.default

private func scratch<T>(_ body: (URL) throws -> T) throws -> T {
    let dir = fm.temporaryDirectory.appendingPathComponent("robo-test-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    return try body(dir)
}

private func write(_ text: String, to url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

private func mode(_ url: URL) throws -> Int { try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int }

/// Robo's agent files under `tmp/home`.
private func agent(_ tmp: URL, env: [String: String] = [:]) -> AgentHome { AgentHome(home: tmp.appendingPathComponent("home"), env: env) }

private func config(_ a: AgentHome) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: a.configFile)) as! [String: Any]
}

/// A checkout with the agent's SOUL.md in it (what setup checks it runs from).
private func project(_ tmp: URL) throws -> URL {
    let dir = tmp.appendingPathComponent("checkout")
    try write("soul", to: dir.appendingPathComponent("agent/SOUL.md"))
    return dir
}

private let exe = URL(fileURLWithPath: "/Users/test/Robo.app/Contents/MacOS/robo")  // what native/bundle.sh builds
private let bareBinary = URL(fileURLWithPath: "/Users/test/robo/native/.build/debug/robo")  // no Info.plist next to it
private let uv = "/opt/fake/uv"

@Suite struct SetupTests {
    // --- the agent's files and its connection ---

    @Test func theAgentFilesLiveUnderTheHome() {
        let a = AgentHome(home: URL(fileURLWithPath: "/Users/jane"), env: [:])
        #expect(a.dir.path == "/Users/jane/.local/share/robo/agent")
        #expect(a.configFile.path == "/Users/jane/.local/share/robo/agent/config.json")
        #expect(a.logFile.path == "/Users/jane/Library/Logs/Robo/agent.log")
        #expect(a.servicePATH == "/Users/jane/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        #expect(AgentHome(env: ["HOME": "/Users/other"]).home.path == "/Users/other")  // Path.home() honours $HOME
    }

    @Test func theConnectionIsTheConfiguredPortAndTheServerKey() throws {
        try scratch { tmp throws in
            let a = agent(tmp)
            #expect(throws: SetupError.self) { try a.connection() }  // no server key: `robo setup` first
            try write("  s3rver \n", to: a.keyFile("server_key"))
            #expect(try a.connection() == ("http://127.0.0.1:8765", "s3rver"))  // no /p/robo, trimmed
            try write("{\"port\": 9100}", to: a.configFile)
            #expect(try a.connection().url == "http://127.0.0.1:9100")
            try write("{\"port\": 70000}", to: a.configFile)
            #expect(try a.connection().url == "http://127.0.0.1:8765")  // nonsense: the default
            let other = agent(tmp, env: ["ROBO_AGENT_URL": "http://127.0.0.1:9"])
            #expect(try other.connection() == ("http://127.0.0.1:9", "s3rver") && other.otherAgent)
        }
    }

    @Test func aDeadAgentURLNeedsNoKey() throws {
        try scratch { tmp throws in
            let c = try agent(tmp, env: ["ROBO_AGENT_URL": "http://127.0.0.1:9"]).connection()
            #expect(c.url == "http://127.0.0.1:9" && c.key == "")
        }
    }

    @Test func aConfigThatIsNotJSONGivesTheDefaultPort() throws {
        try scratch { tmp throws in
            let a = agent(tmp)
            try write("not json", to: a.configFile)
            #expect(a.port == 8765)
        }
    }

    @Test func personaStampIsTheStartOfTheHashOfTheSoul() throws {
        // the values are `printf v1 | shasum -a 256`, cut to 8
        try scratch { tmp throws in
            let dir = tmp.appendingPathComponent("agent")
            let a = agent(tmp)
            #expect(a.personaStamp(agentDir: dir) == "e3b0c442")  // no SOUL.md: the hash of nothing
            try write("v1", to: dir.appendingPathComponent("SOUL.md"))
            #expect(a.personaStamp(agentDir: dir) == "3bfc2695")
            try write("x", to: dir.appendingPathComponent("skills/s/SKILL.md"))  // only SOUL.md counts
            #expect(a.personaStamp(agentDir: dir) == "3bfc2695")
            try write("v2", to: dir.appendingPathComponent("SOUL.md"))
            #expect(a.personaStamp(agentDir: dir) == "fb04dcb6")
        }
    }

    @Test func theServiceCommandRunsTheAgentWithUv() throws {
        try scratch { tmp throws in
            let a = agent(tmp)
            try write("{\"uv_path\": \"/x/uv\"}", to: a.configFile)
            let checkout = URL(fileURLWithPath: "/src/robo")
            #expect(a.serviceCommand(checkout: checkout) == ["/x/uv", "run", "--project", "/src/robo", "robo-agent", "serve"])
            let fake = tmp.appendingPathComponent("home/.local/bin/uv")  // where the service PATH finds it
            try write("#!/bin/sh\n", to: fake)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            try write("{}", to: a.configFile)
            #expect(a.serviceCommand(checkout: checkout)?.first == fake.path)
            #expect(Setup.findUV(a) == fake.path)
        }
    }

    @Test func noServiceIsStartedForAnotherAgent() throws {
        try scratch { tmp throws in
            let a = agent(tmp, env: ["ROBO_AGENT_URL": "http://127.0.0.1:9"])
            try write("{\"uv_path\": \"/x/uv\"}", to: a.configFile)
            #expect(a.service(launch: { _, _, _ in Issue.record("launched"); return FakeProcess() }) == nil)
            let own = agent(tmp).service()
            #expect(own?.command.first == "/x/uv" && own?.environment["PATH"] == agent(tmp).servicePATH)
            #expect(own?.environment["ROBO_AGENT_URL"] == nil && own?.log == agent(tmp).logFile)
        }
    }

    // --- keeping the service up ---

    @Test func aHealthyAgentIsNeverStarted() {
        let launches = Counter()
        let s = service(healthy: { true }, launches: launches)
        #expect(s.ensure() && launches.n == 0)
        s.stop()  // not ours: nothing to end
    }

    @Test func aDownAgentIsStartedOnceAndWaitedFor() {
        let launches = Counter(), polls = Counter()
        let child = FakeProcess()
        let s = service(healthy: { polls.n += 1; return polls.n > 3 }, launches: launches, child: child)
        #expect(s.ensure() && launches.n == 1)
        #expect(launches.argv == ["/x/uv", "run", "robo-agent", "serve"] && launches.env == ["PATH": "/p"])
        #expect(s.ensure() && launches.n == 1)  // up now
        s.stop()
        #expect(child.terminated == 1 && !child.isRunning)
        s.stop()
        #expect(child.terminated == 1)  // once
    }

    @Test func aStartingAgentIsNotStartedTwice() {
        let launches = Counter()
        let child = FakeProcess()
        let s = service(healthy: { false }, launches: launches, child: child, wait: 1)
        #expect(!s.ensure() && launches.n == 1)  // never answered within the wait
        #expect(!s.ensure() && launches.n == 1)  // its process still runs: no second one
        child.isRunning = false  // it died
        #expect(!s.ensure() && launches.n == 2)  // the next request starts it again
    }

    @Test func aChildThatDiesEndsTheWaitAtOnce() {
        let launches = Counter(), naps = Counter()
        let child = FakeProcess()
        let s = AgentService(command: ["uv"], environment: [:], log: URL(fileURLWithPath: "/dev/null"), healthy: { false },
                             launch: { _, _, _ in launches.n += 1; child.isRunning = false; return child }, wait: 30,
                             sleep: { _ in naps.n += 1 })
        #expect(!s.ensure() && naps.n == 1)
    }

    @Test func aLaunchThatFailsIsFalseNotACrash() {
        let s = AgentService(command: ["/nope/uv"], environment: [:], log: URL(fileURLWithPath: "/dev/null"), healthy: { false },
                             launch: { _, _, _ in throw CocoaError(.fileNoSuchFile) }, sleep: { _ in })
        #expect(!s.ensure())
    }

    @Test func theRealLauncherAppendsToAPrivateLog() throws {
        try scratch { tmp throws in
            let log = tmp.appendingPathComponent("Logs/Robo/agent.log")
            let p = try AgentService.launch(["/bin/sh", "-c", "echo \"$GREETING\"; echo err >&2"], ["GREETING": "hi"], log)
            while p.isRunning { Thread.sleep(forTimeInterval: 0.02) }
            let again = try AgentService.launch(["/bin/sh", "-c", "echo again"], [:], log)
            while again.isRunning { Thread.sleep(forTimeInterval: 0.02) }
            #expect(try read(log) == "hi\nerr\nagain\n" && mode(log) == 0o600)
        }
    }

    // --- `robo key` ---

    @Test func keySetWritesOneLinePrivatelyAndPrintsNoKey() throws {
        try scratch { tmp throws in
            let a = agent(tmp)
            var out: [String] = [], err: [String] = []
            let secret = "sk-ant-api03-SECRETVALUE"
            #expect(runKey(["set", "deepseek"], agent: a, readSecret: { "  \(secret)\n" }, out: { out.append($0) }, err: { err.append($0) }) == 0)
            let file = a.keyFile("api_key")
            #expect(try read(file) == secret + "\n" && mode(file) == 0o600 && mode(a.dir) == 0o700)
            #expect(a.hasDeepSeekKey)
            #expect(runKey(["status"], agent: a, readSecret: { nil }, out: { out.append($0) }, err: { err.append($0) }) == 0)
            #expect(out.suffix(2) == ["deepseek: set", "server: not set"])
            #expect(!(out + err).joined().contains(secret))
            #expect(try fm.contentsOfDirectory(atPath: a.dir.path) == ["api_key"])  // no temp file left
        }
    }

    @Test func keySetRefusesNothingOrJunkAndUnknownNames() throws {
        try scratch { tmp throws in
            let a = agent(tmp)
            var err: [String] = []
            for bad in [nil, "", "   \n", "two words", "tab\there", "caf\u{E9}", String(repeating: "k", count: 1025)] as [String?] {
                #expect(runKey(["set", "deepseek"], agent: a, readSecret: { bad }, out: { _ in }, err: { err.append($0) }) == 1)
            }
            #expect(!fm.fileExists(atPath: a.keyFile("api_key").path))
            for args in [[], ["set"], ["set", "anthropic"], ["set", "supermemory"], ["set", "deepseek", "sk-in-argv"], ["show"]] {
                #expect(runKey(args, agent: a, readSecret: { Issue.record("read"); return nil }, out: { _ in }, err: { err.append($0) }) == 2)
            }
            #expect(!err.joined().contains("sk-in-argv"))
            #expect(!fm.fileExists(atPath: a.dir.path))  // refused before anything is written
        }
    }

    // --- `robo setup` ---

    @Test func setupWritesTheConfigAndTheServerKey() throws {
        try scratch { tmp throws in
            let a = agent(tmp)
            let lines = try Setup.report(agent: a, executable: exe, project: try project(tmp), uv: { _ in uv })
            let c = try config(a)
            #expect(Set(c.keys) == ["port", "model", "uv_path"])
            #expect(c["port"] as? Int == 8765 && c["model"] as? String == "deepseek-flash" && c["uv_path"] as? String == uv)
            #expect(try mode(a.configFile) == 0o600 && mode(a.dir) == 0o700)
            let key = try #require(a.readKey("server_key"))
            #expect(try key.count >= 43 && mode(a.keyFile("server_key")) == 0o600)
            #expect(!lines.joined().contains(key))
            #expect(lines.first == "- wrote robo's agent settings (\(a.configFile.path))")
            #expect(lines.contains("- made the key the app uses with robo's agent"))
            #expect(lines.last == "- next: run `robo key set deepseek` (robo's agent needs your DeepSeek API key)")
            _ = try Setup.report(agent: a, executable: exe, project: try project(tmp), uv: { _ in uv })
            #expect(a.readKey("server_key") == key)  // kept
        }
    }

    @Test func setupKeepsWhatIsThereAndNamesThisUv() throws {
        try scratch { tmp throws in
            let a = agent(tmp)
            try write("{\"approvals\": \"manual\", \"model\": \"claude-opus-5-5\", \"port\": 9001, \"mine\": [1],"
                      + " \"uv_path\": \"/old/uv\", \"vault\": \"/v\"}", to: a.configFile)
            let lines = try Setup.report(agent: a, executable: exe, project: try project(tmp), uv: { _ in uv })
            let c = try config(a)
            #expect(c["approvals"] as? String == "manual" && c["model"] as? String == "claude-opus-5-5" && c["port"] as? Int == 9001)
            #expect(c["mine"] as? [Int] == [1] && c["vault"] as? String == "/v")  // keys it does not know stay
            #expect(c["uv_path"] as? String == uv)  // always this uv
            #expect(lines.first == "- updated robo's agent settings")
        }
    }

    @Test func aConfigThatIsNotJSONIsLeftAlone() throws {
        try scratch { tmp throws in
            let a = agent(tmp)
            try write("{ my edit, broken", to: a.configFile)
            #expect(throws: SetupError.self) {
                try Setup.report(agent: a, executable: exe, project: try project(tmp), uv: { _ in uv })
            }
            #expect(try read(a.configFile) == "{ my edit, broken")
            #expect(!fm.fileExists(atPath: a.home.appendingPathComponent("Library/LaunchAgents").path))
        }
    }

    // On macOS 26.7 the parser refuses 1e999 but reads -1e999 as -infinity, and writing that back raises an exception no Swift code
    // can catch: only -1e999 reaches writeConfig's guard, and without the guard this test crashes.
    @Test(arguments: ["1e999", "-1e999"])
    func aConfigThatCannotBeWrittenBackIsLeftAlone(number: String) throws {
        try scratch { tmp throws in
            let a = agent(tmp)
            try write("{\"mine\": \(number)}", to: a.configFile)
            #expect(throws: SetupError.self) {
                try Setup.report(agent: a, executable: exe, project: try project(tmp), uv: { _ in uv })
            }
            #expect(try read(a.configFile) == "{\"mine\": \(number)}")
            #expect(!fm.fileExists(atPath: a.home.appendingPathComponent("Library/LaunchAgents").path))
        }
    }

    @Test func setupRefusesABareBinaryNoUvOrAMovedCheckoutBeforeWritingAnything() throws {
        try scratch { tmp throws in
            let a = agent(tmp)
            #expect(throws: SetupError.self) {
                try Setup.report(agent: a, executable: bareBinary, project: try project(tmp), uv: { _ in uv })
            }
            #expect(throws: SetupError.self) {
                try Setup.report(agent: a, executable: exe, project: try project(tmp), uv: { _ in nil })
            }
            #expect(throws: SetupError.self) {
                try Setup.report(agent: a, executable: exe, project: tmp.appendingPathComponent("moved"), uv: { _ in uv })
            }
            #expect(!fm.fileExists(atPath: a.dir.path))
            #expect(!fm.fileExists(atPath: a.home.appendingPathComponent("Library").path))
        }
    }

    // --- the file writer: private from the first byte ---

    @Test func atomicWriteMakesAPrivateFileInAPrivateFolder() throws {
        try scratch { tmp throws in
            let file = tmp.appendingPathComponent("new/folders/secret")
            let folder = file.deletingLastPathComponent()
            try Host.atomicWrite(Data("one".utf8), to: file)
            #expect(try read(file) == "one" && mode(file) == 0o600 && mode(folder) == 0o700)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try Host.atomicWrite(Data("two".utf8), to: file)
            #expect(try read(file) == "two" && mode(file) == 0o600)
            #expect(try mode(folder) == 0o755)  // a folder that was there is left as it is
            #expect(try fm.contentsOfDirectory(atPath: folder.path) == ["secret"])  // no temp file left
        }
    }

    @Test func theTempFileIsNeverReadableByOthers() throws {
        // Watch every file in the folder while atomicWrite writes (the temp file has a random name).
        try scratch { tmp throws in
            let file = tmp.appendingPathComponent("secret")
            final class Watch: @unchecked Sendable { var stop = false; var exposed: [String] = []; var sightings = 0 }
            let watch = Watch()
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                var st = stat()
                while !watch.stop {
                    for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where stat(tmp.appendingPathComponent(name).path, &st) == 0 {
                        if name != "secret" { watch.sightings += 1 }
                        if st.st_mode & 0o077 != 0 { watch.exposed.append("\(name) \(String(st.st_mode & 0o777, radix: 8))") }
                    }
                }
                done.signal()
            }
            let secret = String(repeating: "k", count: 200_000)  // a long write widens the window
            for i in 0..<150 { try Host.atomicWrite(Data("\(i)\(secret)".utf8), to: file) }
            watch.stop = true
            done.wait()
            #expect(watch.exposed.isEmpty, "seen with mode \(Set(watch.exposed)) (\(watch.exposed.count) times, \(watch.sightings) temp sightings)")
        }
    }

    @Test func aFailedAtomicWriteLeavesNoTempFile() throws {
        try scratch { tmp throws in
            let target = tmp.appendingPathComponent("dir")
            try fm.createDirectory(at: target.appendingPathComponent("inside"), withIntermediateDirectories: true)
            #expect(throws: (any Error).self) { try Host.atomicWrite(Data("x".utf8), to: target) }  // a non-empty folder cannot be replaced
            #expect(try fm.contentsOfDirectory(atPath: tmp.path) == ["dir"])
        }
    }

    // --- `robo setup` as the CLI runs it ---

    /// Everything `robo setup` touches, in a temp home with the DeepSeek key already saved.
    private func cli(_ tmp: URL) throws -> () throws -> [String] {
        let a = agent(tmp)
        try write("sk-x\n", to: a.keyFile("api_key"))
        let checkout = try project(tmp)
        return { try Setup.report(agent: a, executable: exe, project: checkout, uv: { _ in uv }) }
    }

    @Test func setupPrintsWhatItDid() throws {
        try scratch { tmp throws in
            #expect(try cli(tmp)() == [
                "- wrote robo's agent settings (\(agent(tmp).configFile.path))",
                "- made the key the app uses with robo's agent",
                "- robo now starts when you log in (`\(exe.path)` starts it now)",
            ])
        }
    }

    @Test func setupWithNothingToDoSaysSo() throws {
        try scratch { tmp throws in
            let run = try cli(tmp)
            _ = try run()
            #expect(try run() == ["- already set up, nothing changed"])
        }
    }

    @Test func runSetupRefusesWhatItDoesNotKnow() {
        #expect(runSetup(["--bogus"]) == 2)
        #expect(runSetup(["--moodle", "https://lms.uni.example"]) == 2)  // no argument is known any more
    }
    // --- the launch agent ---

    @Test func theLaunchAgentStartsTheAppAtLoginAndNeedsNoExtension() throws {
        try scratch { tmp throws in
            let home = tmp.appendingPathComponent("home")
            let done = try Setup.launchAgent(home: home, executable: exe)
            let file = home.appendingPathComponent("Library/LaunchAgents/ai.robo.plist")
            let agent = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as! [String: Any]
            #expect(agent["Label"] as? String == "ai.robo" && agent["RunAtLoad"] as? Bool == true)
            #expect(agent["ProcessType"] as? String == "Interactive")
            #expect(agent["ProgramArguments"] as? [String] == [exe.path])  // the app itself, not `uv run`
            #expect(agent["StandardErrorPath"] as? String == home.appendingPathComponent("Library/Logs/robo.log").path)
            #expect(agent["StandardOutPath"] as? String == agent["StandardErrorPath"] as? String)
            #expect(!fm.fileExists(atPath: home.appendingPathComponent(".local/share/gnome-shell").path))
            #expect(done.count == 1 && done[0].contains("log in") && done[0].contains(exe.path))
            #expect(try Setup.launchAgent(home: home, executable: exe).isEmpty)  // idempotent
            let moved = try Setup.launchAgent(home: home, executable: URL(fileURLWithPath: "/Applications/Robo.app/Contents/MacOS/robo"))
            #expect(moved.count == 1)  // a new executable rewrites the agent
        }
    }

    @Test func theLaunchAgentPlistMatchesByteForByte() throws {
        // plistlib.dumps of the same dict (home /Users/test), as Python's _launch_agent() would write it.
        let python = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n\t<key>Label</key>\n\t<string>ai.robo</string>\n\t<key>ProcessType</key>\n\t<string>Interactive</string>\n\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>/Users/test/Robo.app/Contents/MacOS/robo</string>\n\t</array>\n\t<key>RunAtLoad</key>\n\t<true/>\n\t<key>StandardErrorPath</key>\n\t<string>/Users/test/Library/Logs/robo.log</string>\n\t<key>StandardOutPath</key>\n\t<string>/Users/test/Library/Logs/robo.log</string>\n</dict>\n</plist>\n"
        try scratch { tmp throws in
            // The home is a temp dir, so rebuild Python's text with that home's log path.
            let home = tmp.appendingPathComponent("home")
            _ = try Setup.launchAgent(home: home, executable: exe)
            let written = try read(home.appendingPathComponent("Library/LaunchAgents/ai.robo.plist"))
            #expect(written == python.replacingOccurrences(of: "/Users/test/Library/Logs", with: home.path + "/Library/Logs"))
        }
    }

    @Test(arguments: [
        "/Users/me/robo/native/.build/debug/robo", "/Users/me/robo/native/.build/release/robo",  // swift run, swift build
        "/Applications/Robo.app/Contents/MacOS/other", "/Applications/Robo.app/Contents/Resources/robo",
        "/Applications/Robo/Contents/MacOS/robo", "/usr/local/bin/robo",
    ])
    func theLaunchAgentRefusesAnythingButTheAppBundle(path: String) throws {
        // A bare binary has no Info.plist, so no NSMicrophoneUsageDescription: under launchd it would be its own
        // TCC client and be killed at the first microphone access.
        try scratch { tmp throws in
            do {
                _ = try Setup.launchAgent(home: tmp, executable: URL(fileURLWithPath: path))
                Issue.record("expected SetupError for \(path)")
            } catch let e as SetupError {
                #expect(e.description.contains("bundle.sh") && e.description.contains(path))
            }
            #expect(!fm.fileExists(atPath: tmp.appendingPathComponent("Library").path))
        }
    }

    @Test func aLaunchAgentThatCannotBeWrittenIsASetupError() throws {
        try scratch { tmp throws in
            try write("x", to: tmp.appendingPathComponent("Library"))  // a file where the folder should be
            #expect(throws: SetupError.self) { try Setup.launchAgent(home: tmp, executable: exe) }
        }
    }

    // --- the day a chat session is named after ---

    @Test func aCalendarDayExistsOnlyWhenTheDateDoes() {
        #expect(CalendarDay(year: 2024, month: 2, day: 29)?.iso == "2024-02-29" && CalendarDay(year: 2000, month: 2, day: 29) != nil)
        #expect(CalendarDay(year: 7, month: 3, day: 5)?.iso == "0007-03-05")
        for (y, m, d) in [(1900, 2, 29), (2026, 2, 29), (2026, 4, 31), (2026, 13, 1), (2026, 1, 0), (0, 1, 1), (10000, 1, 1)] {
            #expect(CalendarDay(year: y, month: m, day: d) == nil, "\(y)-\(m)-\(d)")
        }
    }

    @Test func aCalendarDayIsTheLocalDayOfItsDate() {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .autoupdatingCurrent
        for (h, m) in [(0, 0), (23, 59)] {
            let date = local.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: h, minute: m))!
            #expect(CalendarDay(date).iso == "2026-10-11")
        }
    }
}

/// A process that runs until it is told to stop.
private final class FakeProcess: AgentProcess, @unchecked Sendable {
    var isRunning = true
    var terminated = 0
    func terminate() { terminated += 1; isRunning = false }
}

private final class Counter: @unchecked Sendable {
    var n = 0
    var argv: [String] = []
    var env: [String: String] = [:]
}

/// A service over fakes: no process, no network, no real time.
private func service(healthy: @escaping () -> Bool, launches: Counter, child: FakeProcess = FakeProcess(), wait: Double = 30) -> AgentService {
    AgentService(command: ["/x/uv", "run", "robo-agent", "serve"], environment: ["PATH": "/p"], log: URL(fileURLWithPath: "/dev/null"),
                 healthy: healthy, launch: { argv, env, _ in
                     launches.n += 1
                     (launches.argv, launches.env) = (argv, env)
                     child.isRunning = true
                     return child
                 }, wait: wait, sleep: { _ in })
}
