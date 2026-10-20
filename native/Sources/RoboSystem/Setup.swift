// `robo setup`: give Hermes a `robo` profile served by the host gateway at /p/robo/.
// Port of src/robo/setup.py (macOS only) and the setup/signin parts of src/robo/cli.py.
//
// Hermes runs one host gateway for every profile; a profile's API is the host's API server under
// `/p/<profile>/`, authenticated with that profile's OWN key. So setup turns on the host API server
// (loopback only), gives robo its own key, installs the persona/skills/guard and sets robo's config.
// The one difference from Python: the ai.robo LaunchAgent starts this app's executable, not `uv run`.
import CryptoKit
import Foundation

public struct SetupError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

/// Where Hermes keeps robo's profile for one user: `home` is the user's home, `env` the environment
/// (`HERMES_HOME`, `ROBO_HERMES_URL`). Tests pass a temp home; only the CLI entry points use the real one.
public struct HermesProfile {
    public var home: URL
    public var env: [String: String]

    /// Without `home`, `$HOME` (like Python's `Path.home()`; Foundation's own home call ignores it).
    public init(home: URL? = nil, env: [String: String] = ProcessInfo.processInfo.environment) {
        self.env = env
        let fallback = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        self.home = home ?? URL(fileURLWithPath: fallback)
    }

    /// `$HERMES_HOME`, else `~/.hermes`.
    public var hermesHome: URL {
        env["HERMES_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".hermes")
    }

    public var dir: URL { hermesHome.appendingPathComponent("profiles/\(Setup.profile)") }

    /// Robo's Brave profile (school logins), inside the 0700 Hermes home.
    public var braveDir: URL { dir.appendingPathComponent("brave") }

    /// Short hash of the installed SOUL.md and skills.
    ///
    /// Hermes builds a session's system prompt once, so robo starts a new session whenever this
    /// changes; otherwise a running day's chat would never see an updated persona or skill.
    public func personaStamp() -> String {
        let skills = Setup.files(under: dir.appendingPathComponent("skills")).filter { $0.last!.hasSuffix(".md") }
        var h = SHA256()
        for rel in ([["SOUL.md"]] + skills.map { ["skills"] + $0 }).sorted(by: Setup.pathOrder) {
            guard let data = FileManager.default.contents(atPath: rel.reduce(dir, { $0.appendingPathComponent($1) }).path)
            else { continue }  // a missing SOUL.md, or a folder called *.md
            h.update(data: Data(rel.joined(separator: "/").utf8) + [0] + data + [0])
        }
        return h.finalize().prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// (base URL, robo key) for HermesClient; `ROBO_HERMES_URL` overrides the URL.
    public func connection() throws -> (url: String, key: String) {
        guard let key = try Setup.readEnv(dir.appendingPathComponent(".env"))["API_SERVER_KEY"], !key.isEmpty else {
            throw SetupError("Hermes has no robo profile key yet: run `robo setup` first.")
        }
        let port = try Setup.readEnv(hermesHome.appendingPathComponent(".env"))["API_SERVER_PORT"] ?? "8642"
        return (env["ROBO_HERMES_URL"] ?? "http://127.0.0.1:\(port)/p/\(Setup.profile)", key)
    }

    /// What `cli._client()` does before it builds the HermesClient: the connection, after making sure
    /// robo's Brave is up for school browsing (chat still works without it; school questions will say so).
    public func clientConnection(ensureBrowser: (URL) throws -> Bool = { try Browser.ensure($0) },
                                 warn: (String) -> Void = Host.warn) throws -> (url: String, key: String) {
        let connection = try connection()
        do { _ = try ensureBrowser(braveDir) } catch let e as BrowserError { warn("robo: \(e)") }
        return connection
    }
}

public enum Setup {
    public static let profile = "robo"
    static let installed = ["SOUL.md", "skills", "plugins"]  // what of the templates lands in the profile
    static let launchAgentLabel = "ai.robo"  // ~/Library/LaunchAgents/ai.robo.plist starts robo at login
    /// SOUL.md's rule for desktop apps.
    static let desktopApps = "Open GUI apps on this Mac with `open -a \"<App>\"` from the terminal."
        + " Prefer the terminal or\n  files when they do the job without the GUI."

    /// This checkout, wherever it was cloned (Python: `Path(__file__).resolve().parents[2]`).
    static let checkout = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let toolsets = ["browser", "web", "vision", "skills", "memory", "session_search", "todo",
                           "terminal", "file", "computer_use", "code_execution"]

    /// The model robo's profile is configured with (`model.default`), for the card's header chip.
    public static var model: String { hermesConfig.first { $0.0 == "model.default" }?.1 ?? "" }

    /// robo's profile config, applied with `hermes -p robo config set` (which refuses unknown keys).
    static let hermesConfig: [(String, String)] = [
        ("model.provider", "anthropic"),
        ("model.default", "claude-sonnet-5.5"),
        // Runs arriving at /p/robo/v1/runs resolve their tools as platform "api_server". The user gave
        // robo the whole laptop: apps (computer_use), terminal, files, browser, web.
        ("platform_toolsets.api_server", "[" + toolsets.map { "\"\($0)\"" }.joined(separator: ", ") + "]"),
        // Reads, notes and undoable steps run unasked; robo-guard's "ask"s (send, reply, forward, delete,
        // move, invites, Moodle submit) show Allow/Deny in the card, and one nobody answers is denied
        // after 120 s. "off" approves every ask (the setting until 2026-10-19). A change here reaches
        // the live profile only when the user runs `robo setup`.
        ("approvals.mode", "manual"),
        // These hold in every mode: no request may touch robo's own Hermes setup
        // (persona, plugins, config). robo-guard blocks file writes and skill edits there too.
        ("approvals.deny", "[\"*hermes*\"]"),
        ("approvals.timeout", "120"),
        // GNOME Wayland: the native backend has no target-activation adapter here (`hermes
        // computer-use doctor`), so robo drives X11/XWayland windows; SOUL.md says how to open apps so.
        ("computer_use.native_wayland", "false"),
        ("memory.memory_enabled", "true"),
        ("memory.user_profile_enabled", "true"),
        // Self-evolving: after a conversation Hermes reviews it and saves what it learned (memory,
        // new skills). The curator stays off so robo's installed skills are never archived.
        ("auxiliary.background_review.enabled", "true"),
        ("curator.enabled", "false"),
        // "off" keeps the built-in browser_* tools that robo-guard can judge; unset would pick the
        // Browser Use `browser_exec` tool, which is hidden without the terminal toolset.
        ("browser.backend", "off"),
        // Robo's own Brave (Browser), signed in to school sites only. The user's everyday Brave
        // locks its login databases while open, so Hermes cannot borrow that profile.
        ("browser.use_real_profile", "false"),
        ("browser.cdp_url", Browser.cdpURL),
        ("plugins.enabled", "[\"robo-guard\"]"),
    ]

    // MARK: dotenv files

    /// KEY=VALUE lines of a dotenv file (comments and bare words skipped, quotes trimmed).
    static func readEnv(_ url: URL) throws -> [String: String] {
        guard Host.exists(url) else { return [:] }
        var out: [String: String] = [:]
        for line in Host.splitLines(try Host.readText(url)) {
            let (key, found, value) = Host.partition(Host.trimmed(line), "=")
            if found, !key.isEmpty, !key.hasPrefix("#") {
                out[Host.trimmed(key)] = Host.trimmed(value).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
        }
        return out
    }

    /// Set keys in a dotenv file in place (other lines untouched), mode 0600. True if it changed.
    @discardableResult
    static func setEnv(_ url: URL, _ values: [(String, String)]) throws -> Bool {
        let old = Host.exists(url) ? try Host.readText(url) : nil
        var todo = values
        var lines: [String] = []
        for line in Host.splitLines(old ?? "") {
            let key = Host.trimmed(Host.partition(line, "=").0)
            if let i = todo.firstIndex(where: { $0.0 == key }) {
                lines.append("\(key)=\(todo.remove(at: i).1)")
            } else {
                lines.append(line)
            }
        }
        lines += todo.map { "\($0.0)=\($0.1)" }
        let text = lines.joined(separator: "\n") + "\n"
        if old == text { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Host.replaceFile(url, with: text, mode: 0o600)
        return true
    }

    /// `secrets.token_urlsafe(n)`: n random bytes, base64url without padding.
    static func tokenURLSafe(_ n: Int) -> String {
        Data((0..<n).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: templates

    /// The files under `root` as component lists relative to it (`Path.rglob("*")` filtered by `is_file`).
    static func files(under root: URL) -> [[String]] {
        var found: [[String]] = []
        func walk(_ rel: [String]) {
            let dir = rel.reduce(root) { $0.appendingPathComponent($1) }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let path = rel + [name]
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir)
                else { continue }
                if isDir.boolValue { walk(path) } else { found.append(path) }
            }
        }
        walk([])
        return found
    }

    /// Python orders paths component by component (so "a/x" < "a-b/x", unlike the plain strings).
    static func pathOrder(_ a: [String], _ b: [String]) -> Bool {
        a.lexicographicallyPrecedes(b) { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// Copy template files over `dst`'s, filling {{KEY}}s in order; True if any file changed.
    static func copyTree(_ src: URL, to dst: URL, fill: [(String, String)],
                         only: [String]? = installed) throws -> Bool {
        var changed = false
        for rel in files(under: src) where !rel.contains("__pycache__") && (only?.contains(rel[0]) ?? true) {
            var data = try Data(contentsOf: rel.reduce(src) { $0.appendingPathComponent($1) })
            for (key, value) in fill {
                let needle = Data("{{\(key)}}".utf8), replacement = Data(value.utf8)
                var from = data.startIndex
                while let hit = data.range(of: needle, in: from..<data.endIndex) {
                    data.replaceSubrange(hit, with: replacement)
                    from = hit.lowerBound + replacement.count
                }
            }
            let target = rel.reduce(dst) { $0.appendingPathComponent($1) }
            if try !Host.exists(target) || Data(contentsOf: target) != data {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target)
                changed = true
            }
        }
        return changed
    }

    /// The Moodle base URL, normalised; robo's browser may open only https sites.
    static func moodleURL(_ url: String) throws -> String {
        let bad = SetupError("The Moodle address must look like https://moodle.your-school.edu, not '\(url)'.")
        // urlsplit: tabs and newlines vanish, the scheme is case-blind, the netloc runs to the first / ? #
        let s = String(String.UnicodeScalarView(Host.trimmed(url).unicodeScalars.filter { ![9, 10, 13].contains($0.value) }))
        guard s.lowercased().unicodeScalars.starts(with: "https://".unicodeScalars) else { throw bad }
        let rest = s.unicodeScalars.dropFirst(8)
        let end = rest.firstIndex { "/?#".unicodeScalars.contains($0) } ?? rest.endIndex
        let netloc = String(rest[..<end])
        let path = String(rest[end...].prefix { $0 != "#" }.prefix { $0 != "?" })
        // .hostname: after the last "@", inside [] for an IPv6 address, else up to the first ":"
        let hostinfo = String(netloc.unicodeScalars.split(separator: "@", omittingEmptySubsequences: false).last!)
        let (_, bracketed, inside) = Host.partition(hostinfo, "[")
        let host = bracketed ? Host.partition(inside, "]").0 : Host.partition(hostinfo, ":").0
        guard netloc.contains("[") == netloc.contains("]"), !host.isEmpty else { throw bad }
        var base = try "https://" + netloc + path.replacing(Regex(#"/(?:my|login|course|calendar|mod)(?:/.*)?$"#), with: "")
        while base.unicodeScalars.last == "/" { base.unicodeScalars.removeLast() }
        return base
    }

    // MARK: setup

    static func runHermes(_ cmd: [String]) throws {
        let done = try Host.run(cmd, timeout: 180)
        if done.status != 0 {
            throw SetupError("`\(cmd.prefix(5).joined(separator: " "))` failed: "
                             + Host.trimmed(done.stderr.isEmpty ? done.stdout : done.stderr))
        }
    }

    /// Poll the gateway's /health until it answers 200 (no key needed); false after `timeout` seconds.
    static func waitHealthy(_ p: HermesProfile, timeout: TimeInterval = 90,
                            sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)) throws -> Bool {
        let health = try p.connection().url.components(separatedBy: "/p/")[0] + "/health"
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < end {
            if Host.httpStatus(health, timeout: 3) == 200 { return true }
            sleep(2)
        }
        return false
    }

    /// Idempotent; returns what it did. Restarts the host gateway only when something changed.
    static func hermes(_ p: HermesProfile, templates: URL, robo: String,
                       config: [(String, String)] = hermesConfig,
                       run: ([String]) throws -> Void = runHermes,
                       wait: (HermesProfile) throws -> Bool = { try waitHealthy($0) },
                       moodle: String? = nil) throws -> [String] {
        let moodle = try moodle.map(moodleURL)
        var done: [String] = []
        let hostEnv = p.hermesHome.appendingPathComponent(".env")
        let hostKey = try readEnv(hostEnv)["API_SERVER_KEY"].flatMap { $0.isEmpty ? nil : $0 } ?? tokenURLSafe(32)
        if try setEnv(hostEnv, [("API_SERVER_ENABLED", "true"), ("API_SERVER_KEY", hostKey)]) {
            done.append("enabled the host API server on 127.0.0.1 (default profile .env)")
        }
        if !Host.exists(p.dir) {
            try run(["hermes", "profile", "create", profile, "--no-alias",
                     "--description", "Robo desktop study buddy (robot face app)"])
            done.append("created the robo Hermes profile")
        }
        let roboEnv = p.dir.appendingPathComponent(".env")
        if (try readEnv(roboEnv)["API_SERVER_KEY"] ?? "").isEmpty {
            try setEnv(roboEnv, [("API_SERVER_KEY", tokenURLSafe(32))])
            done.append("gave robo its own API key")
        }
        if let moodle, try setEnv(roboEnv, [("MOODLE_BASE_URL", moodle)]) {
            done.append("set your Moodle address to \(moodle)")
        }
        let lms = try readEnv(roboEnv)["MOODLE_BASE_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? "not set"
        let fill = [("MOODLE_BASE_URL", lms), ("ROBO", robo),
                    ("VAULT", Host.path(Vault.dir(home: p.home))),  // where drafts, plans and notes go; see Vault
                    ("DESKTOP_APPS", desktopApps)]
        if try copyTree(templates, to: p.dir, fill: fill) {
            done.append("installed the persona, skills and guard")
        }
        let cfg = p.dir.appendingPathComponent("config.yaml")
        let before = (try? Data(contentsOf: cfg)) ?? Data()
        for (key, value) in config { try run(["hermes", "-p", profile, "config", "set", key, value]) }
        if ((try? Data(contentsOf: cfg)) ?? Data()) != before { done.append("updated robo's Hermes config") }
        if !done.isEmpty {
            try run(["hermes", "gateway", "restart"])
            if !(try wait(p)) {
                throw SetupError("The Hermes gateway did not come back: check `hermes gateway status`.")
            }
            done.append("restarted the Hermes gateway")
        }
        return done
    }

    /// `path` as one shell word: as it is when it has only [A-Za-z0-9_./-], else in single quotes.
    static func shellWord(_ path: String) -> String {
        let plain = path.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "_./-".unicodeScalars.contains($0)) }
        return plain && !path.isEmpty ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Only the bundled app may be started at login: a bare binary (`swift run`, .build/debug/robo) has no
    /// Info.plist, so no NSMicrophoneUsageDescription, and under launchd it is its own TCC client and is killed
    /// at the first microphone access.
    static func requireApp(_ executable: URL) throws {
        guard Host.path(executable).hasSuffix(".app/Contents/MacOS/robo") else {
            throw SetupError("robo must start from its app bundle at login, not from \(Host.path(executable)): "
                             + "run native/bundle.sh and run `robo setup` with the app it builds (build/Robo.app/Contents/MacOS/robo).")
        }
    }

    /// macOS: launchd starts robo at each login. No extension: Quartz gives the focused app.
    static func launchAgent(home: URL, executable: URL) throws -> [String] {
        try requireApp(executable)
        let log = Host.path(home.appendingPathComponent("Library/Logs/robo.log"))
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "Label": launchAgentLabel, "ProgramArguments": [Host.path(executable)],
            "RunAtLoad": true, "ProcessType": "Interactive",
            "StandardOutPath": log, "StandardErrorPath": log,
        ] as [String: Any], format: .xml, options: 0)
        let path = home.appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
        if (try? Data(contentsOf: path)) == data { return [] }
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: path)
        } catch {
            throw SetupError("Could not write \(Host.path(path)): \(error.localizedDescription)")
        }
        return ["robo now starts when you log in (`\(Host.path(executable))` starts it now)"]
    }

    /// `robo setup`: Hermes, then the LaunchAgent, then the vault; the "- ..." lines it prints.
    static func report(moodle: String?, profile p: HermesProfile, executable: URL, project: URL,
                       run: ([String]) throws -> Void = runHermes,
                       wait: (HermesProfile) throws -> Bool = { try waitHealthy($0) },
                       running: () -> Bool = { Vault.obsidianRunning() }) throws -> [String] {
        try requireApp(executable)  // before anything is written
        let templates = project.appendingPathComponent("hermes")
        guard Host.exists(templates.appendingPathComponent("SOUL.md")) else {
            throw SetupError("robo's Hermes templates are not in \(Host.path(templates)): run robo from the checkout it was built in.")
        }
        // Skills run `{{ROBO}} plan ...`: this app, as a word for the shell (inside terminal(command="...")).
        let done = try hermes(p, templates: templates, robo: shellWord(Host.path(executable)), run: run, wait: wait, moodle: moodle)
            + launchAgent(home: p.home, executable: executable)
            + Vault.ensure(home: p.home, running: running)
        return (done.isEmpty ? ["already set up, nothing changed"] : done).map { "- \($0)" }
    }

    /// The Moodle address `robo signin` opens a tab for, if the profile has one. It goes into Brave's command
    /// line, where a value starting with `--` would be a flag: only an https address, normalised as setup
    /// stores it, is passed on.
    static func signinMoodle(_ p: HermesProfile) throws -> String? {
        guard let lms = try readEnv(p.dir.appendingPathComponent(".env"))["MOODLE_BASE_URL"], !lms.isEmpty else { return nil }
        return try moodleURL(lms)
    }

    /// The Moodle address for the LMS posts scan, or nil: the profile has none, or the `school-posts` skill is not installed in it
    /// (`robo setup` installs it). The scan stays off until both are there. Reads only.
    public static func postsMoodle(_ p: HermesProfile) -> String? {
        let skill = p.dir.appendingPathComponent("skills/school/school-posts/SKILL.md")
        guard FileManager.default.fileExists(atPath: skill.path) else { return nil }
        return (try? signinMoodle(p)) ?? nil
    }

    static func signinNotice(lms: Bool) -> String {
        "Sign in to Outlook, Teams" + (lms ? " and your LMS" : "") + " in the Brave window that opened. "
            + "When Microsoft asks \"Stay signed in?\", choose Yes, or the sign-in is lost when robo's browser restarts."
    }
}

/// `robo setup [--moodle URL]` (`args` are what follows `setup`); the exit code.
public func runSetup(_ args: [String], executable: URL? = nil, project: URL? = nil) -> Int32 {
    var moodle: String?
    var rest = args[...]
    while let arg = rest.popFirst() {
        if arg == "--moodle", let value = rest.popFirst() {
            moodle = value
        } else if arg.hasPrefix("--moodle=") {
            moodle = String(arg.dropFirst("--moodle=".count))
        } else {
            Host.warn("usage: robo setup [--moodle URL]\nrobo: error: unrecognized arguments: \(arg)")
            return 2
        }
    }
    do {
        let lines = try Setup.report(moodle: moodle, profile: HermesProfile(),
                                     executable: executable ?? Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
                                     project: project ?? Setup.checkout)
        lines.forEach { print($0) }
        return 0
    } catch {
        Host.warn("robo: \(error)")
        return 1
    }
}

/// `robo signin`: show robo's Brave once so the user can sign in to school sites; the exit code.
public func runSignin() -> Int32 {
    let profile = HermesProfile()
    do {
        let lms = try Setup.signinMoodle(profile)
        try Browser.signin(profile.braveDir, extra: lms.map { [$0] } ?? [])
        print(Setup.signinNotice(lms: lms != nil))
        print("Press Enter here when you are signed in everywhere... ", terminator: "")
        fflush(stdout)
        _ = readLine()
        Browser.stop(profile.braveDir)  // robo works in the background from now on
        _ = try Browser.ensure(profile.braveDir)
        print("Done: robo's browser runs in the background with those logins.")
        return 0
    } catch {
        Host.warn("robo: \(error)")
        return 1
    }
}
