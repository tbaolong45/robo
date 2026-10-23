// Port of tests/test_setup.py and the setup tests of tests/test_cli.py (macOS only: the GNOME extension
// and the Linux half of the desktop-apps rule are not ported). A temp dir stands in for the home and for
// $HERMES_HOME, and `hermes` is a fake that records its commands, so nothing real is touched.
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

/// A profile whose $HERMES_HOME is `tmp` and whose home is `tmp/home`.
private func profile(_ tmp: URL, env: [String: String] = [:]) -> HermesProfile {
    HermesProfile(home: tmp.appendingPathComponent("home"), env: env.merging(["HERMES_HOME": tmp.path]) { a, _ in a })
}

/// `profile`, with the host and robo keys already there (what the tests of the templates start from).
private func readyProfile(_ tmp: URL) throws -> (HermesProfile, URL) {
    try write("API_SERVER_ENABLED=true\nAPI_SERVER_KEY=k\n", to: tmp.appendingPathComponent(".env"))
    let robo = tmp.appendingPathComponent("profiles/robo")
    try write("API_SERVER_KEY=r\n", to: robo.appendingPathComponent(".env"))
    return (profile(tmp), robo)
}

/// A fake `hermes`: records the commands; like the real one it rewrites config.yaml only on a new value.
private final class FakeHermes {
    var calls: [[String]] = []
    let root: URL
    init(_ root: URL) { self.root = root }

    func run(_ cmd: [String]) throws {
        calls.append(cmd)
        if Array(cmd[1...2]) == ["profile", "create"] {
            try fm.createDirectory(at: root.appendingPathComponent("profiles/robo"), withIntermediateDirectories: true)
        }
        if cmd.count > 6, Array(cmd[3...4]) == ["config", "set"] {
            let cfg = root.appendingPathComponent("profiles/robo/config.yaml")
            let line = "\(cmd[5]): \(cmd[6])\n"
            let old = (try? read(cfg)) ?? ""
            if !old.contains(line) { try write(old + line, to: cfg) }
        }
    }
}

private func templatesWith(_ files: [String: String], in tmp: URL) throws -> URL {
    let dir = tmp.appendingPathComponent("templates")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for (path, text) in files { try write(text, to: dir.appendingPathComponent(path)) }
    return dir
}

private let exe = URL(fileURLWithPath: "/Users/test/Robo.app/Contents/MacOS/robo")  // what native/bundle.sh builds
private let bareBinary = URL(fileURLWithPath: "/Users/test/robo/native/.build/debug/robo")  // no Info.plist next to it

@Suite struct SetupTests {
    // --- dotenv files ---

    @Test func setEnvAppendsUpdatesAndKeepsPrivate() throws {
        try scratch { tmp throws in
            let env = tmp.appendingPathComponent(".env")
            try write("# keep me\nA=1\nB=2\n", to: env)
            #expect(try Setup.setEnv(env, [("B", "3"), ("C", "4")]) == true)
            #expect(try read(env) == "# keep me\nA=1\nB=3\nC=4\n")
            #expect(try mode(env) == 0o600)
            #expect(try Setup.setEnv(env, [("B", "3")]) == false)
        }
    }

    @Test func setEnvCreatesMissingFile() throws {
        try scratch { tmp throws in
            let env = tmp.appendingPathComponent("sub/.env")
            #expect(try Setup.setEnv(env, [("K", "v")]) == true)
            #expect(try read(env) == "K=v\n")
            #expect(try mode(env) == 0o600)
            #expect(!fm.fileExists(atPath: env.path + ".tmp"))  // the temp file is renamed over it
        }
    }

    @Test func readEnvIgnoresCommentsAndQuotes() throws {
        try scratch { tmp throws in
            let env = tmp.appendingPathComponent(".env")
            try write("# X=no\nX='yes'\nY=\"two words\"\nZ\n", to: env)
            #expect(try Setup.readEnv(env) == ["X": "yes", "Y": "two words"])
            #expect(try Setup.readEnv(tmp.appendingPathComponent("missing")) == [:])
        }
    }

    // Expected values below come from running Python's read_env / set_env on the same text.
    @Test(arguments: [
        ("A=1\r\nB=2\r\n", "B=2", false, "A=1\r\nB=2\r\n"),  // Python reads \r\n as \n: nothing to change
        ("A=1\r\nB=2\r\n", "B=3", true, "A=1\nB=3\n"),
        ("\n\nA=1\n\n", "A=2", true, "\n\nA=2\n\n"),  // blank lines stay
        ("A=1", "A=1", true, "A=1\n"),  // no final newline: written with one
        ("A=1", "A=2,Z=9", true, "A=2\nZ=9\n"),
        ("", "A=1", true, "A=1\n"),
        ("\n", "A=1", true, "\nA=1\n"),
        ("A=\u{E9}\nB=\"q\"\n", "B='z'", true, "A=\u{E9}\nB='z'\n"),
        ("  A = 1 \nA=2\nexport A=3\nZ\n#A=4\n", "A=x,Z=y", true, "A=x\nA=2\nexport A=3\nZ=y\n#A=4\n"),  // only the first A
        ("API_SERVER_KEY=\nX=1\n", "API_SERVER_KEY=k,API_SERVER_ENABLED=true", true,
         "API_SERVER_KEY=k\nX=1\nAPI_SERVER_ENABLED=true\n"),
    ])
    func setEnvEdgeCases(existing: String, values: String, changed: Bool, result: String) throws {
        try scratch { tmp throws in
            let env = tmp.appendingPathComponent(".env")
            try Data(existing.utf8).write(to: env)
            let pairs = values.split(separator: ",").map { kv -> (String, String) in
                let p = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(p[0]), p.count > 1 ? String(p[1]) : "")
            }
            #expect(try Setup.setEnv(env, pairs) == changed)
            #expect(try String(contentsOf: env, encoding: .utf8) == result)
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
            #expect(throws: (any Error).self) { try Setup.setEnv(env, [("A", "1")]) }
        }
    }

    // --- the profile and its connection ---

    @Test func connectionUsesProfileKeyAndHostPort() throws {
        try scratch { tmp throws in
            try write("API_SERVER_PORT=9000\nAPI_SERVER_KEY=host-secret\n", to: tmp.appendingPathComponent(".env"))
            try write("API_SERVER_KEY=robo-secret\n", to: tmp.appendingPathComponent("profiles/robo/.env"))
            let c = try profile(tmp).connection()
            #expect(c.url == "http://127.0.0.1:9000/p/robo" && c.key == "robo-secret")
            let override = try profile(tmp, env: ["ROBO_HERMES_URL": "http://127.0.0.1:9/"]).connection()
            #expect(override.url == "http://127.0.0.1:9/")
        }
    }

    @Test func connectionWithoutSetupThrows() throws {
        try scratch { tmp throws in
            do {
                _ = try profile(tmp).connection()
                Issue.record("expected SetupError")
            } catch let e as SetupError {
                #expect(e.description.contains("robo setup"))
            }
        }
    }

    @Test func theProfilePathsFollowHermesHomeThenTheHome() {
        let home = URL(fileURLWithPath: "/Users/jane")
        let byDefault = HermesProfile(home: home, env: [:])
        #expect(byDefault.hermesHome.path == "/Users/jane/.hermes")
        #expect(byDefault.dir.path == "/Users/jane/.hermes/profiles/robo")
        #expect(byDefault.braveDir.path == "/Users/jane/.hermes/profiles/robo/brave")
        #expect(HermesProfile(home: home, env: ["HERMES_HOME": "/srv/h"]).dir.path == "/srv/h/profiles/robo")
        #expect(HermesProfile(home: home, env: ["HERMES_HOME": ""]).hermesHome.path == "/Users/jane/.hermes")  // empty = unset
        #expect(HermesProfile(env: ["HOME": "/Users/other"]).home.path == "/Users/other")  // Path.home() honours $HOME
    }

    @Test func clientConnectionKeepsChatWorkingWithoutBrave() throws {
        // cli._client(): a Brave that will not start is a warning, anything else is an error.
        try scratch { tmp throws in
            let (p, robo) = try readyProfile(tmp)
            var asked: [URL] = [], warned: [String] = []
            let c = try p.clientConnection(ensureBrowser: { asked.append($0); throw BrowserError("no brave") },
                                           warn: { warned.append($0) })
            #expect(c.key == "r" && c.url == "http://127.0.0.1:8642/p/robo")
            #expect(asked.map(\.path) == [robo.appendingPathComponent("brave").path])
            #expect(warned == ["robo: no brave"])
            #expect(throws: SetupError.self) { try p.clientConnection(ensureBrowser: { _ in throw SetupError("x") }, warn: { _ in }) }
            #expect(throws: SetupError.self) { try profile(tmp.appendingPathComponent("none")).clientConnection(ensureBrowser: { _ in true }) }
        }
    }

    // --- setup() ---

    @Test func setupIsIdempotentAndRestartsOnlyOnChange() throws {
        try scratch { tmp throws in
            let p = profile(tmp)
            try write("SLACK_BOT_TOKEN=x\n", to: tmp.appendingPathComponent(".env"))
            let templates = try templatesWith(["SOUL.md": "soul", "skills/school/mail/SKILL.md": "skill"], in: tmp)
            let hermes = FakeHermes(tmp)

            _ = try Setup.hermes(p, templates: templates, robo: "robo", config: [("a.b", "1")], run: hermes.run, wait: { _ in true })
            let host = try Setup.readEnv(tmp.appendingPathComponent(".env"))
            let robo = try Setup.readEnv(tmp.appendingPathComponent("profiles/robo/.env"))
            #expect(host["SLACK_BOT_TOKEN"] == "x" && host["API_SERVER_ENABLED"] == "true")
            #expect(host["API_SERVER_KEY"]!.count >= 32 && robo["API_SERVER_KEY"]!.count >= 32)
            #expect(host["API_SERVER_KEY"] != robo["API_SERVER_KEY"])
            #expect(robo["API_SERVER_ENABLED"] == nil)  // served by the host gateway, never its own listener
            #expect(try read(tmp.appendingPathComponent("profiles/robo/SOUL.md")) == "soul")
            #expect(try read(tmp.appendingPathComponent("profiles/robo/skills/school/mail/SKILL.md")) == "skill")
            #expect(Array(hermes.calls[0].prefix(5)) == ["hermes", "profile", "create", "robo", "--no-alias"])
            #expect(hermes.calls.contains(["hermes", "-p", "robo", "config", "set", "a.b", "1"]))
            #expect(hermes.calls.contains(["hermes", "gateway", "restart"]))

            hermes.calls.removeAll()
            let again = try Setup.hermes(p, templates: templates, robo: "robo", config: [("a.b", "1")], run: hermes.run, wait: { _ in true })
            #expect(again.isEmpty)
            #expect(!hermes.calls.contains { Array($0[1...2]) == ["profile", "create"] })
            #expect(!hermes.calls.contains(["hermes", "gateway", "restart"]))
            #expect(try Setup.readEnv(tmp.appendingPathComponent(".env"))["API_SERVER_KEY"] == host["API_SERVER_KEY"])
        }
    }

    @Test func aConfigChangeAloneRestarts() throws {
        try scratch { tmp throws in
            try write("API_SERVER_ENABLED=true\nAPI_SERVER_KEY=k\n", to: tmp.appendingPathComponent(".env"))
            let robo = tmp.appendingPathComponent("profiles/robo")
            try write("API_SERVER_KEY=r\n", to: robo.appendingPathComponent(".env"))
            try write("old\n", to: robo.appendingPathComponent("config.yaml"))
            var calls: [[String]] = []
            let done = try Setup.hermes(profile(tmp), templates: tmp.appendingPathComponent("none"), robo: "robo",
                                        config: [("a", "1")], run: {
                calls.append($0)
                if $0.count > 4, Array($0[3...4]) == ["config", "set"] { try write("new\n", to: robo.appendingPathComponent("config.yaml")) }
            }, wait: { _ in true })
            #expect(done.contains("updated robo's Hermes config"))
            #expect(calls.contains(["hermes", "gateway", "restart"]))
        }
    }

    @Test func theGatewayThatDoesNotComeBackIsAnError() throws {
        try scratch { tmp throws in
            do {  // a fresh home, so something changes and the gateway must restart
                _ = try Setup.hermes(profile(tmp), templates: tmp.appendingPathComponent("none"), robo: "robo",
                                     config: [("a", "1")], run: { _ in }, wait: { _ in false })
                Issue.record("expected SetupError")
            } catch let e as SetupError {
                #expect(e.description.contains("hermes gateway status"))
            }
        }
    }

    @Test func moodleURLIsStoredAndFilledIntoSkills() throws {
        try scratch { tmp throws in
            let (p, robo) = try readyProfile(tmp)
            let templates = try templatesWith(["skills/m/SKILL.md": "Moodle is {{MOODLE_BASE_URL}}."], in: tmp)

            _ = try Setup.hermes(p, templates: templates, robo: "robo", config: [], run: { _ in }, wait: { _ in true })
            #expect(try read(robo.appendingPathComponent("skills/m/SKILL.md")).contains("not set"))

            _ = try Setup.hermes(p, templates: templates, robo: "robo", config: [], run: { _ in }, wait: { _ in true },
                                 moodle: "https://moodle.uni.example/")
            #expect(try Setup.readEnv(robo.appendingPathComponent(".env"))["MOODLE_BASE_URL"] == "https://moodle.uni.example")
            #expect(try read(robo.appendingPathComponent("skills/m/SKILL.md")) == "Moodle is https://moodle.uni.example.")
        }
    }

    // Skills run `{{ROBO}} activity ...` inside terminal(command="..."): the app, as one shell word.
    @Test(arguments: [
        ("/Users/test/Robo.app/Contents/MacOS/robo", "/Users/test/Robo.app/Contents/MacOS/robo activity --days 1"),
        ("/Users/me/My Apps/Robo.app/Contents/MacOS/robo", "'/Users/me/My Apps/Robo.app/Contents/MacOS/robo' activity --days 1"),
        ("/Users/o'brien/Robo.app/Contents/MacOS/robo", "'/Users/o'\\''brien/Robo.app/Contents/MacOS/robo' activity --days 1"),
    ])
    func theAppCommandIsFilledIntoSkills(executable: String, filled: String) throws {
        try scratch { tmp throws in
            let project = tmp.appendingPathComponent("checkout")
            try write("soul", to: project.appendingPathComponent("hermes/SOUL.md"))
            try write("{{ROBO}} activity --days 1", to: project.appendingPathComponent("hermes/skills/p/SKILL.md"))
            let p = profile(tmp)
            _ = try Setup.report(moodle: nil, profile: p, executable: URL(fileURLWithPath: executable), project: project,
                                 run: { _ in }, wait: { _ in true }, running: { true })
            #expect(try read(p.dir.appendingPathComponent("skills/p/SKILL.md")) == filled)
        }
    }

    @Test(arguments: ["/a/Robo.app/Contents/MacOS/robo", "/a b/robo", "/it's/robo", "/q\"uote/robo", "/$HOME/`x`/robo", "/\u{E9}/robo", "/semi;colon/robo"])
    func theShellWordSurvivesTheShell(path: String) throws {
        let out = try Host.run(["sh", "-c", "printf %s " + Setup.shellWord(path)], timeout: 5)
        #expect(out.stdout == path)
    }

    @Test func theShellWordIsThePathItselfWhenItIsPlain() {
        #expect(Setup.shellWord("/Applications/Robo.app/Contents/MacOS/robo") == "/Applications/Robo.app/Contents/MacOS/robo")
        #expect(Setup.shellWord("/a_b-c.d/robo") == "/a_b-c.d/robo")
        #expect(Setup.shellWord("/a b") == "'/a b'" && Setup.shellWord("") == "''" && Setup.shellWord("/it's") == "'/it'\\''s'")
    }

    @Test func theRealStudyPlanSkillRunsTheAppForActivityAndPlan() throws {
        try scratch { tmp throws in
            let (p, robo) = try readyProfile(tmp)
            let word = Setup.shellWord(exe.path)
            _ = try Setup.hermes(p, templates: Setup.checkout.appendingPathComponent("hermes"), robo: word,
                                 config: [], run: { _ in }, wait: { _ in true })
            let skill = try read(robo.appendingPathComponent("skills/school/study-plan/SKILL.md"))
            #expect(skill.contains("`terminal(command=\"\(word) activity --days 1\", timeout=60)`"))
            #expect(skill.contains("`terminal(command=\"\(word) plan --tasks /tmp/robo-plan/1432-tasks.json --busy /tmp/robo-plan/1432-busy.json\", timeout=60)`"))
            #expect(!skill.contains("uv run") && !skill.contains("{{"))
            // The template is the filled skill with only the command swapped back.
            let template = try read(Setup.checkout.appendingPathComponent("hermes/skills/school/study-plan/SKILL.md"))
            let filled = template.replacingOccurrences(of: "{{ROBO}}", with: word)
            #expect(skill == filled)
        }
    }

    @Test func theVaultPathIsFilledIntoSkills() throws {
        // Skills and the persona name the vault through {{VAULT}}; Vault.dir is the only copy.
        try scratch { tmp throws in
            let (p, robo) = try readyProfile(tmp)
            let templates = try templatesWith(["skills/v/SKILL.md": "write to {{VAULT}}/Drafts/<title>.md"], in: tmp)
            _ = try Setup.hermes(p, templates: templates, robo: "robo", config: [], run: { _ in }, wait: { _ in true })
            #expect(try read(robo.appendingPathComponent("skills/v/SKILL.md"))
                    == "write to \(Vault.dir(home: p.home).path)/Drafts/<title>.md")
        }
    }

    @Test func everyPlaceholderInTheRealTemplatesGetsFilled() throws {
        try scratch { tmp throws in
            let (p, robo) = try readyProfile(tmp)
            _ = try Setup.hermes(p, templates: Setup.checkout.appendingPathComponent("hermes"), robo: "robo",
                                 config: [], run: { _ in }, wait: { _ in true })
            let placeholder = try NSRegularExpression(pattern: #"\{\{[A-Z_]+\}\}"#)
            var left: [String] = []
            for rel in Setup.files(under: robo) where rel.last!.hasSuffix(".md") {
                let text = try read(rel.reduce(robo) { $0.appendingPathComponent($1) })
                if placeholder.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { left.append(rel.joined(separator: "/")) }
            }
            #expect(left.isEmpty, "unfilled placeholders in \(left)")
        }
    }

    @Test func templatesAreCopiedWithTheFillOrderAndSkipPyCaches() throws {
        try scratch { tmp throws in
            let (p, robo) = try readyProfile(tmp)
            let templates = try templatesWith([
                "SOUL.md": "{{DESKTOP_APPS}}|{{NOPE}}", "skills/s/SKILL.md": "{{VAULT}}{{VAULT}}",
                "plugins/g/__pycache__/x.pyc": "no", "plugins/g/__init__.py": "py", "other/not-installed.md": "no",
            ], in: tmp)
            _ = try Setup.hermes(p, templates: templates, robo: "robo", config: [], run: { _ in }, wait: { _ in true })
            #expect(try read(robo.appendingPathComponent("SOUL.md")) == "\(Setup.desktopApps)|{{NOPE}}")  // unknown ones stay
            let vault = Vault.dir(home: p.home).path
            #expect(try read(robo.appendingPathComponent("skills/s/SKILL.md")) == vault + vault)
            #expect(fm.fileExists(atPath: robo.appendingPathComponent("plugins/g/__init__.py").path))
            #expect(!fm.fileExists(atPath: robo.appendingPathComponent("plugins/g/__pycache__").path))
            #expect(!fm.fileExists(atPath: robo.appendingPathComponent("other").path))
        }
    }

    @Test(arguments: ["moodle.uni.example", "http://moodle.uni.example", "https://"])
    func theMoodleURLMustBeHTTPS(bad: String) throws {
        try scratch { tmp throws in
            #expect(throws: SetupError.self) {
                try Setup.hermes(profile(tmp), templates: tmp, robo: "robo", config: [], run: { _ in }, wait: { _ in true }, moodle: bad)
            }
            #expect(!fm.fileExists(atPath: tmp.appendingPathComponent(".env").path))  // refused before anything is written
        }
    }

    @Test func personaStampChangesWithSoulOrSkills() throws {
        try scratch { tmp throws in
            let robo = tmp.appendingPathComponent("profiles/robo")
            try write("v1", to: robo.appendingPathComponent("SOUL.md"))
            try write("a", to: robo.appendingPathComponent("skills/s/SKILL.md"))
            let p = profile(tmp)
            let first = p.personaStamp()
            #expect(first == p.personaStamp() && first.count == 8)
            try write("v2", to: robo.appendingPathComponent("SOUL.md"))
            let second = p.personaStamp()
            try write("b", to: robo.appendingPathComponent("skills/s/SKILL.md"))
            #expect(Set([first, second, p.personaStamp()]).count == 3)
        }
    }

    @Test func personaStampFollowsPythonsHashAndPathOrder() throws {
        // 384c250b is what Python's persona_stamp() gives for this tree: a/ sorts before a-b/ by path
        // component (not by string), uppercase before lowercase, and dotfiles and *.md names are handled;
        // a folder called dir.md, a .txt and the plugins folder are not hashed.
        try scratch { tmp throws in
            let robo = tmp.appendingPathComponent("profiles/robo")
            for (path, text) in [
                ("SOUL.md", "soul\n"), ("skills/school/a/SKILL.md", "a\n"), ("skills/school/a-b/SKILL.md", "ab\n"),
                ("skills/school/a/notes/ref.md", "ref\n"), ("skills/Z.md", "z\n"), ("skills/s.txt", "no\n"),
                ("skills/school/a.md", "dot\n"), ("plugins/p.md", "not a skill\n"), ("skills/.hidden.md", "h\n"),
                ("skills/aa/.md", "empty stem\n"),
            ] { try write(text, to: robo.appendingPathComponent(path)) }
            try fm.createDirectory(at: robo.appendingPathComponent("skills/school/a/dir.md"), withIntermediateDirectories: true)
            #expect(profile(tmp).personaStamp() == "384c250b")
        }
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

    // --- the config, the launch agent, the desktop-apps rule ---

    @Test func theConfigCommandsEqualPythons() {
        // setup.CONFIG as `hermes -p robo config set <key> <value>`, in Python's order.
        let python: [[String]] = [
            ["model.provider", "anthropic"],
            ["model.default", "claude-sonnet-5.5"],
            ["platform_toolsets.api_server", "[\"browser\", \"web\", \"vision\", \"skills\", \"memory\", \"session_search\", \"todo\", \"terminal\", \"file\", \"computer_use\", \"code_execution\"]"],
            ["approvals.mode", "off"],
            ["approvals.deny", "[\"*hermes*\"]"],
            ["approvals.timeout", "120"],
            ["computer_use.native_wayland", "false"],
            ["memory.memory_enabled", "true"],
            ["memory.user_profile_enabled", "true"],
            ["auxiliary.background_review.enabled", "true"],
            ["curator.enabled", "false"],
            ["browser.backend", "off"],
            ["browser.use_real_profile", "false"],
            ["browser.cdp_url", "http://127.0.0.1:9333"],
            ["plugins.enabled", "[\"robo-guard\"]"],
        ]
        #expect(Setup.hermesConfig.map { [$0.0, $0.1] } == python)
    }

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

    @Test func setupRefusesABareBinaryBeforeWritingAnything() throws {
        try scratch { tmp throws in
            let p = profile(tmp)
            let hermes = FakeHermes(tmp)
            #expect(throws: SetupError.self) {
                try Setup.report(moodle: nil, profile: p, executable: bareBinary, project: Setup.checkout,
                                 run: hermes.run, wait: { _ in true }, running: { false })
            }
            #expect(hermes.calls.isEmpty && !fm.fileExists(atPath: tmp.appendingPathComponent(".env").path))
            #expect(!fm.fileExists(atPath: Vault.dir(home: p.home).path))
        }
    }

    // --- the dotenv writer: private from the first byte, and through a symlink ---

    @Test func setEnvUpdatesWhatASymlinkPointsAtAndKeepsTheLink() throws {
        // A dotfiles-managed ~/.hermes/.env: replacing the link with a regular file would leave the target stale.
        try scratch { tmp throws in
            let real = tmp.appendingPathComponent("dotfiles/hermes.env")
            try write("# mine\nA=1\n", to: real)
            let link = tmp.appendingPathComponent("home/.env")
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: link, withDestinationURL: real)

            #expect(try Setup.setEnv(link, [("A", "2"), ("B", "3")]) == true)

            #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == real.path)  // still a link
            #expect(try read(real) == "# mine\nA=2\nB=3\n")
            #expect(try mode(real) == 0o600)
            #expect(try Setup.setEnv(link, [("A", "2")]) == false)
            #expect(try fm.contentsOfDirectory(atPath: link.deletingLastPathComponent().path) == [".env"])  // no temp file left
            #expect(try fm.contentsOfDirectory(atPath: real.deletingLastPathComponent().path) == ["hermes.env"])
        }
    }

    @Test func theTempFileIsNeverReadableByOthers() throws {
        // The key was written 0644 and chmod-ed afterwards; watch the temp file while setEnv runs.
        try scratch { tmp throws in
            let env = tmp.appendingPathComponent(".env")
            let temp = env.path + ".tmp"
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
            for i in 0..<150 { try Setup.setEnv(env, [("API_SERVER_KEY", "\(i)\(secret)")]) }
            watch.stop = true
            done.wait()
            #expect(watch.exposed.isEmpty, "temp file seen with mode \(Set(watch.exposed)) (\(watch.exposed.count) of \(watch.sightings) sightings)")
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

    // --- signin ---

    @Test func signinOnlyOpensAnHTTPSMoodleAddress() throws {
        // MOODLE_BASE_URL goes into Brave's command line: a value starting with -- would be a Chromium flag.
        try scratch { tmp throws in
            let p = profile(tmp)
            let env = p.dir.appendingPathComponent(".env")
            #expect(try Setup.signinMoodle(p) == nil)  // no file: no LMS tab
            try write("API_SERVER_KEY=r\nMOODLE_BASE_URL=\n", to: env)
            #expect(try Setup.signinMoodle(p) == nil)
            try write("MOODLE_BASE_URL=https://lms.uni.example/my/\n", to: env)
            #expect(try Setup.signinMoodle(p) == "https://lms.uni.example")  // normalised like setup does
            for bad in ["--remote-debugging-port=1", "--user-data-dir=/tmp/x", "http://lms.uni.example", "lms.uni.example", "file:///etc/passwd"] {
                try write("MOODLE_BASE_URL=\(bad)\n", to: env)
                #expect(throws: SetupError.self, "\(bad)") { try Setup.signinMoodle(p) }
            }
        }
    }

    @Test func aLaunchAgentThatCannotBeWrittenIsASetupError() throws {
        try scratch { tmp throws in
            try write("x", to: tmp.appendingPathComponent("Library"))  // a file where the folder should be
            #expect(throws: SetupError.self) { try Setup.launchAgent(home: tmp, executable: exe) }
        }
    }

    @Test func theDesktopAppsRuleIsFilledForTheMac() throws {
        try scratch { tmp throws in
            let (p, robo) = try readyProfile(tmp)
            let templates = try templatesWith(["SOUL.md": "- {{DESKTOP_APPS}}\n"], in: tmp)
            _ = try Setup.hermes(p, templates: templates, robo: "robo", config: [], run: { _ in }, wait: { _ in true })
            let soul = try read(robo.appendingPathComponent("SOUL.md"))
            #expect(soul.contains("open -a") && !soul.contains("{{"))
            #expect(!soul.contains("GDK_BACKEND"))  // the Linux rule is not installed
        }
    }

    // --- the health wait ---

    @Test func waitHealthyAsksTheGatewaysHealthEndpoint() throws {
        try scratch { tmp throws in
            try write("API_SERVER_KEY=r\n", to: tmp.appendingPathComponent("profiles/robo/.env"))
            let up = LoopbackServer(status: 200), down = LoopbackServer(status: 503)
            func p(_ server: LoopbackServer) -> HermesProfile {  // the gateway is a throwaway local server, never the real one
                profile(tmp, env: ["ROBO_HERMES_URL": "http://127.0.0.1:\(server.port)/p/robo"])
            }
            #expect(try Setup.waitHealthy(p(up), timeout: 5, sleep: { _ in }) == true)
            #expect(up.requests.first?.hasPrefix("GET /health ") == true)
            #expect(try Setup.waitHealthy(p(down), timeout: 0.3, sleep: { _ in }) == false)
        }
    }

    // --- running hermes ---

    @Test func aFailingCommandIsASetupErrorWithItsStderr() throws {
        do {
            try Setup.runHermes(["sh", "-c", "echo oops >&2; exit 3"])
            Issue.record("expected SetupError")
        } catch let e as SetupError {
            #expect(e.description == "`sh -c echo oops >&2; exit 3` failed: oops")
        }
        do {
            try Setup.runHermes(["sh", "-c", "echo only-stdout; exit 1"])
            Issue.record("expected SetupError")
        } catch let e as SetupError {
            #expect(e.description.hasSuffix("failed: only-stdout"))  // stdout when stderr is empty
        }
        try Setup.runHermes(["true"])
    }

    @Test func hostRunCapturesBothStreamsWithoutDeadlockAndTimesOut() throws {
        let out = try Host.run(["sh", "-c", "echo hi; echo err >&2; exit 3"], timeout: 10)
        #expect(out.status == 3 && out.stdout == "hi\n" && out.stderr == "err\n")
        let big = try Host.run(["sh", "-c", "yes | head -c 300000; yes | head -c 300000 >&2"], timeout: 20)
        #expect(big.stdout.utf8.count == 300_000 && big.stderr.utf8.count == 300_000)
        #expect(throws: (any Error).self) { try Host.run(["sleep", "10"], timeout: 0.2) }
        #expect(throws: (any Error).self) { try Host.run(["robo-no-such-command-xyz"], timeout: 1) }
    }

    // --- `robo setup` as the CLI runs it (tests/test_cli.py) ---

    /// Everything `robo setup` touches, in a temp home; `obsidian.json` is there for the vault to join.
    private func cli(_ tmp: URL, running: Bool = false, registerable: Bool = true) throws -> () throws -> [String] {
        let p = profile(tmp)
        if registerable { try write("{\"vaults\":{}}", to: Vault.obsidianConfig(home: p.home)) }
        let hermes = FakeHermes(tmp)
        return { try Setup.report(moodle: nil, profile: p, executable: exe, project: Setup.checkout,
                                  run: hermes.run, wait: { _ in true }, running: { running }) }
    }

    @Test func setupAlsoMakesTheVaultAndPrintsWhatItDid() throws {
        try scratch { tmp throws in
            let lines = try cli(tmp)()
            let vault = Vault.dir(home: tmp.appendingPathComponent("home")).path
            #expect(lines == [
                "- enabled the host API server on 127.0.0.1 (default profile .env)",
                "- created the robo Hermes profile",
                "- gave robo its own API key",
                "- installed the persona, skills and guard",
                "- updated robo's Hermes config",
                "- restarted the Hermes gateway",
                "- robo now starts when you log in (`\(exe.path)` starts it now)",
                "- created your Obsidian vault at \(vault)",
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

    @Test func aFailedHermesStepStopsBeforeTheLaunchAgentAndTheVault() throws {
        try scratch { tmp throws in
            let p = profile(tmp)
            #expect(throws: SetupError.self) {
                try Setup.report(moodle: nil, profile: p, executable: exe, project: Setup.checkout,
                                 run: { _ in throw SetupError("hermes is not installed") }, wait: { _ in true })
            }
            #expect(!fm.fileExists(atPath: p.home.appendingPathComponent("Library/LaunchAgents").path))
            #expect(!fm.fileExists(atPath: Vault.dir(home: p.home).path))
        }
    }

    @Test func aCheckoutWithoutTemplatesIsRefusedBeforeAnythingIsWritten() throws {
        try scratch { tmp throws in
            #expect(throws: SetupError.self) {
                try Setup.report(moodle: nil, profile: profile(tmp), executable: exe, project: tmp.appendingPathComponent("moved"),
                                 run: { _ in }, wait: { _ in true })
            }
            #expect(!fm.fileExists(atPath: tmp.appendingPathComponent(".env").path))
        }
    }

    @Test func runSetupRefusesWhatItDoesNotKnow() {
        #expect(runSetup(["--bogus"]) == 2)
        #expect(runSetup(["--moodle"]) == 2)  // no address after it
    }

    @Test func signinNoticeMatchesPython() {
        #expect(Setup.signinNotice(lms: false) == "Sign in to Outlook, Teams in the Brave window that opened. When Microsoft asks \"Stay signed in?\", choose Yes, or the sign-in is lost when robo's browser restarts.")
        #expect(Setup.signinNotice(lms: true).hasPrefix("Sign in to Outlook, Teams and your LMS in the Brave window"))
    }
}
