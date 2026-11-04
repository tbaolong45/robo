// Port of tests/test_setup.py and the setup tests of tests/test_cli.py (macOS only), for robo's own agent: a temp dir stands in
// for the home, so nothing real is touched (no ~/.local/share/robo, no LaunchAgent, no vault, no agent is started).
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
    // --- dotenv files (only read now: the Moodle address of the old Hermes profile) ---

    @Test func readEnvIgnoresCommentsAndQuotes() throws {
        try scratch { tmp throws in
            let env = tmp.appendingPathComponent(".env")
            try write("# X=no\nX='yes'\nY=\"two words\"\nZ\n", to: env)
            #expect(try Setup.readEnv(env) == ["X": "yes", "Y": "two words"])
            #expect(try Setup.readEnv(tmp.appendingPathComponent("missing")) == [:])
        }
    }

    @Test func readEnvEdgeCases() throws {
        try scratch { tmp throws in
            let env = tmp.appendingPathComponent(".env")
            for (text, expected) in [
                ("A=1\nA=2\n", ["A": "2"]),  // the later line wins
                ("  K = v  \n=novalue\n#c=1\n", ["K": "v"]),
                ("Q=''\"x\"'\nR=\"\"\n", ["Q": "x", "R": ""]),  // all quotes at the ends, not one level
                ("A=b=c\n", ["A": "b=c"]),
                ("A=1\r\nB=2\r\n", ["A": "1", "B": "2"]),
                (" #A=1\nB=2", ["B": "2"]),
                ("'A'=1\n", ["'A'": "1"]),
            ] as [(String, [String: String])] {
                try write(text, to: env)
                #expect(try Setup.readEnv(env) == expected, "\(text.debugDescription)")
            }
        }
    }

    @Test func aDotenvThatIsNotUTF8IsAnErrorNotAnEmptyFile() throws {
        // Python raises UnicodeDecodeError; treating it as empty would let setup overwrite the user's keys.
        try scratch { tmp throws in
            let env = tmp.appendingPathComponent(".env")
            try Data([0x4B, 0x3D, 0xFF, 0xFE, 0x0A]).write(to: env)
            #expect(throws: (any Error).self) { try Setup.readEnv(env) }
        }
    }


    // --- the agent's files and its connection ---

    @Test func theAgentFilesLiveUnderTheHome() {
        let a = AgentHome(home: URL(fileURLWithPath: "/Users/jane"), env: [:])
        #expect(a.dir.path == "/Users/jane/.local/share/robo/agent")
        #expect(a.configFile.path == "/Users/jane/.local/share/robo/agent/config.json")
        #expect(a.logFile.path == "/Users/jane/Library/Logs/Robo/agent.log")
        #expect(a.braveDir.path == "/Users/jane/.hermes/profiles/robo/brave")  // the school logins stay where they are
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

    @Test func aDeadAgentURLNeedsNoKeyAndLeavesBraveAlone() throws {
        try scratch { tmp throws in
            var asked = 0
            let c = try agent(tmp, env: ["ROBO_AGENT_URL": "http://127.0.0.1:9"]).clientConnection(ensureBrowser: { _ in asked += 1; return true })
            #expect(c.url == "http://127.0.0.1:9" && c.key == "" && asked == 0)
        }
    }

    @Test func clientConnectionKeepsChatWorkingWithoutBrave() throws {
        // cli._client(): a Brave that will not start is a warning, anything else is an error.
        try scratch { tmp throws in
            let a = agent(tmp)
            try write("k\n", to: a.keyFile("server_key"))
            var asked: [URL] = [], warned: [String] = []
            let c = try a.clientConnection(ensureBrowser: { asked.append($0); throw BrowserError("no brave") }, warn: { warned.append($0) })
            #expect(c.key == "k" && asked == [a.braveDir] && warned == ["robo: no brave"])
            #expect(throws: SetupError.self) { try a.clientConnection(ensureBrowser: { _ in throw SetupError("x") }, warn: { _ in }) }
        }
    }

    @Test func theModelAndTheMoodleAddressComeFromTheConfig() throws {
        try scratch { tmp throws in
            let a = agent(tmp)
            #expect(a.model == "claude-sonnet-5-5" && a.moodle == nil && Setup.postsMoodle(a) == nil)
            try write("{\"model\": \"claude-opus-5-5\", \"moodle_url\": \"https://lms.uni.example/my/\"}", to: a.configFile)
            #expect(a.model == "claude-opus-5-5" && Setup.postsMoodle(a) == "https://lms.uni.example")
            for bad in ["\"http://lms.uni.example\"", "\"--remote-debugging-port=1\"", "\"\"", "null"] {
                try write("{\"moodle_url\": \(bad)}", to: a.configFile)
                #expect(Setup.postsMoodle(a) == nil, "\(bad)")  // the scan stays off
            }
            try write("not json", to: a.configFile)
            #expect(a.model == "claude-sonnet-5-5" && a.port == 8765)
        }
    }

    @Test func personaStampHashesTheAgentsSoulAndSkills() throws {
        try scratch { tmp throws in
            let dir = tmp.appendingPathComponent("agent")
            let a = agent(tmp)
            try write("v1", to: dir.appendingPathComponent("SOUL.md"))
            try write("a", to: dir.appendingPathComponent("skills/s/SKILL.md"))
            let first = a.personaStamp(agentDir: dir)
            #expect(first == a.personaStamp(agentDir: dir) && first.count == 8)
            try write("other", to: dir.appendingPathComponent("skills/s/notes.md"))  // not a skill file
            try write("x", to: dir.appendingPathComponent("plugins/p/SKILL.md"))  // not under skills/
            #expect(a.personaStamp(agentDir: dir) == first)
            try write("v2", to: dir.appendingPathComponent("SOUL.md"))
            let second = a.personaStamp(agentDir: dir)
            try write("b", to: dir.appendingPathComponent("skills/s/SKILL.md"))
            #expect(Set([first, second, a.personaStamp(agentDir: dir)]).count == 3)
        }
    }

    @Test func personaStampOrdersPathsByComponentLikePython() throws {
        // a/ before a-b/ by path component (not by string): swapping the two skills' texts changes the stamp.
        try scratch { tmp throws in
            let dir = tmp.appendingPathComponent("agent")
            try write("a", to: dir.appendingPathComponent("skills/a/SKILL.md"))
            try write("ab", to: dir.appendingPathComponent("skills/a-b/SKILL.md"))
            let one = agent(tmp).personaStamp(agentDir: dir)
            try write("ab", to: dir.appendingPathComponent("skills/a/SKILL.md"))
            try write("a", to: dir.appendingPathComponent("skills/a-b/SKILL.md"))
            #expect(one != agent(tmp).personaStamp(agentDir: dir))
            #expect(Setup.pathOrder(["a", "x"], ["a-b", "x"]) && !Setup.pathOrder(["a-b", "x"], ["a", "x"]))
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
            #expect(runKey(["set", "anthropic"], agent: a, readSecret: { "  \(secret)\n" }, out: { out.append($0) }, err: { err.append($0) }) == 0)
            let file = a.keyFile("api_key")
            #expect(try read(file) == secret + "\n" && mode(file) == 0o600 && mode(a.dir) == 0o700)
            #expect(a.hasAnthropicKey)
            #expect(runKey(["set", "supermemory"], agent: a, readSecret: { "sm_x" }, out: { out.append($0) }, err: { err.append($0) }) == 0)
            #expect(try read(a.keyFile("supermemory_key")) == "sm_x\n")
            #expect(runKey(["status"], agent: a, readSecret: { nil }, out: { out.append($0) }, err: { err.append($0) }) == 0)
            #expect(out.suffix(3) == ["anthropic: set", "supermemory: set", "server: not set"])
            #expect(!(out + err).joined().contains(secret) && !(out + err).joined().contains("sm_x"))
            #expect(try fm.contentsOfDirectory(atPath: a.dir.path).sorted() == ["api_key", "supermemory_key"])  // no temp file left
        }
    }

    @Test func keySetRefusesNothingOrJunkAndUnknownNames() throws {
        try scratch { tmp throws in
            let a = agent(tmp)
            var err: [String] = []
            for bad in [nil, "", "   \n", "two words", "tab\there", "caf\u{E9}", String(repeating: "k", count: 1025)] as [String?] {
                #expect(runKey(["set", "anthropic"], agent: a, readSecret: { bad }, out: { _ in }, err: { err.append($0) }) == 1)
            }
            #expect(!fm.fileExists(atPath: a.keyFile("api_key").path))
            for args in [[], ["set"], ["set", "openai"], ["set", "anthropic", "sk-in-argv"], ["show"]] {
                #expect(runKey(args, agent: a, readSecret: { Issue.record("read"); return nil }, out: { _ in }, err: { err.append($0) }) == 2)
            }
            #expect(!err.joined().contains("sk-in-argv"))
        }
    }

    // --- `robo setup` ---

    @Test func setupWritesTheConfigAndTheServerKey() throws {
        try scratch { tmp throws in
            let a = agent(tmp)
            let lines = try Setup.report(moodle: nil, agent: a, executable: exe, project: try project(tmp), uv: { _ in uv }, running: { true })
            let c = try config(a)
            #expect(c["port"] as? Int == 8765 && c["model"] as? String == "claude-sonnet-5-5" && c["approvals"] as? String == "off")
            #expect(c["vault"] as? String == Vault.dir(home: a.home).path && c["learn"] as? Bool == true)
            #expect(c["moodle_url"] is NSNull && c["robo_cmd"] as? String == exe.path && c["uv_path"] as? String == uv)
            #expect(try mode(a.configFile) == 0o600 && mode(a.dir) == 0o700)
            let key = try #require(a.readKey("server_key"))
            #expect(try key.count >= 43 && mode(a.keyFile("server_key")) == 0o600)
            #expect(!lines.joined().contains(key))
            #expect(lines.first == "- wrote robo's agent settings (\(a.configFile.path))")
            #expect(lines.contains("- made the key the app uses with robo's agent"))
            #expect(lines.last == "- next: run `robo key set anthropic` (robo's agent needs your Anthropic API key)")
            _ = try Setup.report(moodle: nil, agent: a, executable: exe, project: try project(tmp), uv: { _ in uv }, running: { true })
            #expect(a.readKey("server_key") == key)  // kept
        }
    }

    @Test func setupKeepsWhatTheUserEditedAndNamesThisBuild() throws {
        try scratch { tmp throws in
            let a = agent(tmp)
            try write("{\"approvals\": \"manual\", \"model\": \"claude-opus-5-5\", \"port\": 9001, \"learn\": false, \"mine\": [1],"
                      + " \"moodle_url\": \"https://lms.uni.example\", \"robo_cmd\": \"/old/robo\", \"vault\": \"/v\"}", to: a.configFile)
            let lines = try Setup.report(moodle: nil, agent: a, executable: exe, project: try project(tmp), uv: { _ in uv }, running: { true })
            let c = try config(a)
            #expect(c["approvals"] as? String == "manual" && c["model"] as? String == "claude-opus-5-5" && c["port"] as? Int == 9001)
            #expect(c["learn"] as? Bool == false && c["mine"] as? [Int] == [1] && c["vault"] as? String == "/v")
            #expect(c["moodle_url"] as? String == "https://lms.uni.example")
            #expect(c["robo_cmd"] as? String == exe.path && c["uv_path"] as? String == uv)  // always this build
            #expect(lines.first == "- updated robo's agent settings")
        }
    }

    @Test func setupMovesTheMoodleAddressOverFromHermesAndTakesANewOne() throws {
        try scratch { tmp throws in
            let a = agent(tmp)
            let secret = "API_SERVER_KEY=do-not-print-me"
            try write("\(secret)\nMOODLE_BASE_URL=https://lms.uni.example/my/\n", to: a.home.appendingPathComponent(".hermes/profiles/robo/.env"))
            let lines = try Setup.report(moodle: nil, agent: a, executable: exe, project: try project(tmp), uv: { _ in uv }, running: { true })
            #expect(try config(a)["moodle_url"] as? String == "https://lms.uni.example")
            #expect(lines.contains("- kept your Moodle address from the Hermes profile"))
            #expect(!lines.joined().contains("do-not-print-me") && !fm.fileExists(atPath: a.keyFile("api_key").path))
            #expect(try !read(a.configFile).contains("do-not-print-me"))
            _ = try Setup.report(moodle: "https://moodle.other.example/login/index.php", agent: a, executable: exe,
                                 project: try project(tmp), uv: { _ in uv }, running: { true })
            #expect(try config(a)["moodle_url"] as? String == "https://moodle.other.example")
            try write("MOODLE_BASE_URL=--remote-debugging-port=1\n", to: a.home.appendingPathComponent(".hermes/profiles/robo/.env"))
            #expect(Setup.hermesMoodle(home: a.home) == nil)  // only an https address moves over
        }
    }

    @Test(arguments: ["moodle.uni.example", "http://moodle.uni.example", "https://"])
    func theMoodleURLMustBeHTTPS(bad: String) throws {
        try scratch { tmp throws in
            let a = agent(tmp)
            #expect(throws: SetupError.self) {
                try Setup.report(moodle: bad, agent: a, executable: exe, project: try project(tmp), uv: { _ in uv }, running: { true })
            }
            #expect(!fm.fileExists(atPath: a.dir.path))  // refused before anything is written
        }
    }

    @Test func aConfigThatIsNotJSONIsLeftAlone() throws {
        try scratch { tmp throws in
            let a = agent(tmp)
            try write("{ my edit, broken", to: a.configFile)
            #expect(throws: SetupError.self) {
                try Setup.report(moodle: nil, agent: a, executable: exe, project: try project(tmp), uv: { _ in uv }, running: { true })
            }
            #expect(try read(a.configFile) == "{ my edit, broken")
            #expect(!fm.fileExists(atPath: a.home.appendingPathComponent("Library/LaunchAgents").path))
        }
    }

    @Test func setupRefusesABareBinaryNoUvOrAMovedCheckoutBeforeWritingAnything() throws {
        try scratch { tmp throws in
            let a = agent(tmp)
            #expect(throws: SetupError.self) {
                try Setup.report(moodle: nil, agent: a, executable: bareBinary, project: try project(tmp), uv: { _ in uv }, running: { false })
            }
            #expect(throws: SetupError.self) {
                try Setup.report(moodle: nil, agent: a, executable: exe, project: try project(tmp), uv: { _ in nil }, running: { false })
            }
            #expect(throws: SetupError.self) {
                try Setup.report(moodle: nil, agent: a, executable: exe, project: tmp.appendingPathComponent("moved"), uv: { _ in uv }, running: { false })
            }
            #expect(!fm.fileExists(atPath: a.dir.path) && !fm.fileExists(atPath: Vault.dir(home: a.home).path))
            #expect(!fm.fileExists(atPath: a.home.appendingPathComponent("Library").path))
        }
    }

    // --- signin ---

    @Test func signinOnlyOpensAnHTTPSMoodleAddress() throws {
        // The Moodle address goes into Brave's command line: a value starting with -- would be a Chromium flag.
        try scratch { tmp throws in
            let a = agent(tmp)
            #expect(try Setup.signinMoodle(a) == nil)  // no file: no LMS tab
            try write("{\"moodle_url\": null}", to: a.configFile)
            #expect(try Setup.signinMoodle(a) == nil)
            try write("{\"moodle_url\": \"https://lms.uni.example/my/\"}", to: a.configFile)
            #expect(try Setup.signinMoodle(a) == "https://lms.uni.example")  // normalised like setup does
            for bad in ["--remote-debugging-port=1", "--user-data-dir=/tmp/x", "http://lms.uni.example", "lms.uni.example", "file:///etc/passwd"] {
                try write("{\"moodle_url\": \"\(bad)\"}", to: a.configFile)
                #expect(throws: SetupError.self, "\(bad)") { try Setup.signinMoodle(a) }
            }
        }
    }

    // --- the file writer: private from the first byte, and through a symlink ---

    @Test func replaceFileUpdatesWhatASymlinkPointsAtAndKeepsTheLink() throws {
        try scratch { tmp throws in
            let real = tmp.appendingPathComponent("dotfiles/obsidian.json")
            try write("old", to: real)
            let link = tmp.appendingPathComponent("home/obsidian.json")
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: link, withDestinationURL: real)
            try Host.replaceFile(link, with: "new", mode: 0o600)
            #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == real.path)  // still a link
            #expect(try read(real) == "new" && mode(real) == 0o600)
            #expect(try fm.contentsOfDirectory(atPath: link.deletingLastPathComponent().path) == ["obsidian.json"])  // no temp file left
        }
    }

    @Test func theTempFileIsNeverReadableByOthers() throws {
        // Watch the temp file while replaceFile writes with mode 0600.
        try scratch { tmp throws in
            let file = tmp.appendingPathComponent("secret")
            let temp = file.path + ".tmp"
            final class Watch: @unchecked Sendable { var stop = false; var exposed: [String] = []; var sightings = 0 }
            let watch = Watch()
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                var st = stat()
                while !watch.stop {
                    if stat(temp, &st) == 0 {
                        watch.sightings += 1
                        if st.st_mode & 0o077 != 0 { watch.exposed.append(String(st.st_mode & 0o777, radix: 8)) }
                    }
                }
                done.signal()
            }
            let secret = String(repeating: "k", count: 200_000)  // a long write widens the window
            for i in 0..<150 { try Host.replaceFile(file, with: "\(i)\(secret)", mode: 0o600) }
            watch.stop = true
            done.wait()
            #expect(watch.exposed.isEmpty, "temp file seen with mode \(Set(watch.exposed)) (\(watch.exposed.count) of \(watch.sightings) sightings)")
        }
    }

    // --- `robo setup` as the CLI runs it (tests/test_cli.py) ---

    /// Everything `robo setup` touches, in a temp home; `obsidian.json` is there for the vault to join.
    private func cli(_ tmp: URL, running: Bool = false) throws -> () throws -> [String] {
        let a = agent(tmp)
        try write("{\"vaults\":{}}", to: Vault.obsidianConfig(home: a.home))
        try write("sk-ant-x\n", to: a.keyFile("api_key"))
        let checkout = try project(tmp)
        return { try Setup.report(moodle: nil, agent: a, executable: exe, project: checkout, uv: { _ in uv }, running: { running }) }
    }

    @Test func setupAlsoMakesTheVaultAndPrintsWhatItDid() throws {
        try scratch { tmp throws in
            let lines = try cli(tmp)()
            let home = tmp.appendingPathComponent("home")
            #expect(lines == [
                "- wrote robo's agent settings (\(agent(tmp).configFile.path))",
                "- made the key the app uses with robo's agent",
                "- robo now starts when you log in (`\(exe.path)` starts it now)",
                "- created your Obsidian vault at \(Vault.dir(home: home).path)",
                "- added your Robo vault to Obsidian",
            ])
        }
    }

    @Test func setupPrintsTheVaultMessageEvenWhenNothingElseChanged() throws {
        try scratch { tmp throws in
            let run = try cli(tmp, running: true)  // Obsidian is open: the vault cannot be listed
            _ = try run()
            let again = try run()
            #expect(again.count == 1 && again[0].hasPrefix("- Obsidian is open, so I left its settings alone"))
            #expect(!again.contains { $0.contains("nothing changed") })
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
        #expect(runSetup(["--moodle"]) == 2)  // no address after it
    }

    // --- the Moodle address ---

    @Test(arguments: [
        ("https://lms.mbzuai.ac.ae/my/", "https://lms.mbzuai.ac.ae"),
        ("https://lms.uni.example/my/index.php", "https://lms.uni.example"),
        ("https://uni.example/moodle/my/", "https://uni.example/moodle"),
        ("https://uni.example/moodle/", "https://uni.example/moodle"),
        ("https://lms.uni.example/login/index.php", "https://lms.uni.example"),
    ])
    func theMoodleURLTakesTheBaseOfAPastedPage(pasted: String, base: String) throws {
        #expect(try Setup.moodleURL(pasted) == base)
    }

    // Python's _moodle_url on the same inputs (nil: it raised SetupError).
    @Test(arguments: [
        ("HTTPS://User@Host.Example:8443/my/?q=1#f", "https://User@Host.Example:8443"),
        ("https://[::1]:80/my", "https://[::1]:80"),
        ("  https://m.example/course/view.php?id=3  ", "https://m.example"),
        ("https://m.example///", "https://m.example"),
        ("https://m.example/mod/forum/view.php", "https://m.example"),
        ("https://m.example/mymoodle/my/", "https://m.example/mymoodle"),
        ("https://m.example/a/my/b/login", "https://m.example/a"),
        ("https://m.example/x/modx", "https://m.example/x/modx"),
        ("https://m.example/?x=/my", "https://m.example"),
        ("https://m.example#/my", "https://m.example"),
        ("https://exa\tmple/x", "https://example/x"),
        ("https://m.example/Course/", "https://m.example/Course"),
        ("https://:80/x", nil),
        ("https://user@/x", nil),
        ("https:/x", nil),
        ("ftp://m.example", nil),
        ("", nil),
        ("https://m.example:8443/m/login", "https://m.example:8443/m"),
        ("https://m.example/my/course/", "https://m.example"),
    ] as [(String, String?)])
    func theMoodleURLMatchesPython(input: String, expected: String?) throws {
        if let expected {
            #expect(try Setup.moodleURL(input) == expected)
        } else {
            #expect(throws: SetupError.self) { try Setup.moodleURL(input) }
        }
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
            let lint = try Host.run(["plutil", "-lint", file.path], timeout: 10)
            #expect(lint.status == 0, "\(lint.stdout)\(lint.stderr)")
        }
    }

    @Test func theLaunchAgentIsPythonsPlistByteForByte() throws {
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

    @Test func aFailedReplaceLeavesNoTempFile() throws {
        try scratch { tmp throws in
            let target = tmp.appendingPathComponent("dir")
            try fm.createDirectory(at: target.appendingPathComponent("inside"), withIntermediateDirectories: true)
            #expect(throws: (any Error).self) { try Host.replaceFile(target, with: "x") }  // a non-empty folder cannot be replaced
            #expect(!fm.fileExists(atPath: target.path + ".tmp"))
        }
    }

    @Test func aLaunchAgentThatCannotBeWrittenIsASetupError() throws {
        try scratch { tmp throws in
            try write("x", to: tmp.appendingPathComponent("Library"))  // a file where the folder should be
            #expect(throws: SetupError.self) { try Setup.launchAgent(home: tmp, executable: exe) }
        }
    }

    @Test func hostRunCapturesBothStreamsWithoutDeadlockAndTimesOut() throws {
        let out = try Host.run(["sh", "-c", "echo hi; echo err >&2; exit 3"], timeout: 10)
        #expect(out.status == 3 && out.stdout == "hi\n" && out.stderr == "err\n")
        let big = try Host.run(["sh", "-c", "yes | head -c 300000; yes | head -c 300000 >&2"], timeout: 20)
        #expect(big.stdout.utf8.count == 300_000 && big.stderr.utf8.count == 300_000)
        #expect(throws: (any Error).self) { try Host.run(["sleep", "10"], timeout: 0.2) }
        #expect(throws: (any Error).self) { try Host.run(["robo-no-such-command-xyz"], timeout: 1) }
    }

    @Test func signinNoticeMatchesPython() {
        #expect(Setup.signinNotice(lms: false) == "Sign in to Outlook, Teams in the Brave window that opened. When Microsoft asks \"Stay signed in?\", choose Yes, or the sign-in is lost when robo's browser restarts.")
        #expect(Setup.signinNotice(lms: true).hasPrefix("Sign in to Outlook, Teams and your LMS in the Brave window"))
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
