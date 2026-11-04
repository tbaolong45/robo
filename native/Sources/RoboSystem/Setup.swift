// `robo setup`: robo's agent settings (`AgentHome`: config.json and the server key), the login item and the vault.
// Port of the macOS parts of src/robo/setup.py. The agent fills its own SOUL.md and skills (`<checkout>/agent/`) when it loads them,
// so setup installs no templates; the app starts the agent itself (`AgentService`). The ai.robo LaunchAgent starts this app's
// executable, not `uv run`.
import Foundation

public struct SetupError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

public enum Setup {
    static let launchAgentLabel = "ai.robo"  // ~/Library/LaunchAgents/ai.robo.plist starts robo at login

    /// This checkout, wherever it was cloned (Python: `Path(__file__).resolve().parents[2]`).
    static let checkout = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Robo's agent may ask before an irreversible step ("manual": Allow/Deny on the card) or not ("off", the user's choice since
    /// 2026-10-23). Only a new config.json gets it; a value the user set stays.
    static let defaultApprovals = "off"

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

    // MARK: files

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

    /// uv where the service PATH has it (the app's own PATH under launchd has almost nothing), else nil.
    static func findUV(_ a: AgentHome) -> String? {
        a.servicePATH.split(separator: ":").map { "\($0)/uv" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The Moodle address the Hermes build kept in its profile (`MOODLE_BASE_URL` of `~/.hermes/profiles/robo/.env`, that key only),
    /// normalised; nil when there is none or it is not an https address. Reads only.
    static func hermesMoodle(home: URL) -> String? {
        let env = home.appendingPathComponent(".hermes/profiles/robo/.env")
        guard let url = (try? readEnv(env))?["MOODLE_BASE_URL"], !url.isEmpty else { return nil }
        return try? moodleURL(url)
    }

    /// Write `R/config.json`, keeping what is already there: `port`, `model`, `approvals`, `vault` and `learn` get a default only when
    /// missing, `moodle_url` is `moodle` when given, else the one there, else the Hermes profile's, else null; `robo_cmd` and `uv_path`
    /// always name this build and this uv (like the LaunchAgent). Keys it does not know stay. The "..." lines of what changed.
    static func writeConfig(_ a: AgentHome, executable: URL, uv: String, moodle: String?) throws -> [String] {
        let old = try a.readConfig()
        var config = old
        let defaults: [String: Any] = ["port": AgentHome.defaultPort, "model": AgentHome.defaultModel, "approvals": defaultApprovals,
                                       "vault": Host.path(Vault.dir(home: a.home)), "learn": true]
        for (key, value) in defaults where config[key] == nil || config[key] is NSNull { config[key] = value }
        if let moodle {
            config["moodle_url"] = moodle
        } else if (config["moodle_url"] as? String ?? "").isEmpty {
            config["moodle_url"] = hermesMoodle(home: a.home) ?? NSNull()
        }
        config["robo_cmd"] = Host.path(executable)
        config["uv_path"] = uv
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if (try? Data(contentsOf: a.configFile)) == data { return [] }
        do { try NudgeFiles.atomicWrite(data, to: a.configFile) } catch {
            throw SetupError("Could not write \(Host.path(a.configFile)): \(error.localizedDescription)")
        }
        var done = [old.isEmpty ? "wrote robo's agent settings (\(Host.path(a.configFile)))" : "updated robo's agent settings"]
        if (old["moodle_url"] as? String) != (config["moodle_url"] as? String), config["moodle_url"] is String {
            done.append(moodle == nil ? "kept your Moodle address from the Hermes profile" : "set your Moodle address")
        }
        return done
    }

    /// `robo setup`: the agent's settings and server key, then the LaunchAgent, then the vault; the "- ..." lines it prints.
    static func report(moodle: String?, agent a: AgentHome, executable: URL, project: URL,
                       uv: (AgentHome) -> String? = findUV,
                       running: () -> Bool = { Vault.obsidianRunning() }) throws -> [String] {
        try requireApp(executable)  // before anything is written
        let moodle = try moodle.map(moodleURL)
        let soul = project.appendingPathComponent("agent/SOUL.md")
        guard Host.exists(soul) else {
            throw SetupError("robo's agent is not in \(Host.path(soul.deletingLastPathComponent())): run robo from the checkout it was built in.")
        }
        guard let uv = uv(a) else {
            throw SetupError("uv is not installed (looked in \(a.servicePATH)): install it (`brew install uv`), then run `robo setup` again.")
        }
        var done = try writeConfig(a, executable: executable, uv: uv, moodle: moodle)
        if a.readKey(AgentHome.serverKeyFile) == nil {
            try a.writeKey(try AgentHome.newServerKey(), to: AgentHome.serverKeyFile)
            done.append("made the key the app uses with robo's agent")
        }
        done += try launchAgent(home: a.home, executable: executable) + Vault.ensure(home: a.home, running: running)
        if !a.hasAnthropicKey { done.append("next: run `robo key set anthropic` (robo's agent needs your Anthropic API key)") }
        return (done.isEmpty ? ["already set up, nothing changed"] : done).map { "- \($0)" }
    }

    /// The Moodle address `robo signin` opens a tab for, if config.json has one. It goes into Brave's command line, where a value
    /// starting with `--` would be a flag: only an https address, normalised as setup stores it, is passed on.
    static func signinMoodle(_ a: AgentHome) throws -> String? {
        guard let lms = try a.readConfig()["moodle_url"] as? String, !lms.isEmpty else { return nil }
        return try moodleURL(lms)
    }

    /// The Moodle address for the LMS posts scan, or nil (config.json has none, or not an https one): the scan is off then. Reads only.
    public static func postsMoodle(_ a: AgentHome) -> String? { a.moodle }

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
        let lines = try Setup.report(moodle: moodle, agent: AgentHome(),
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
    let profile = AgentHome()
    do {
        let lms = try Setup.signinMoodle(profile)
        try Browser.signin(profile.braveDir, extra: lms.map { [$0] } ?? [])
        print(Setup.signinNotice(lms: lms != nil))
        print("Press Enter here when you are signed in everywhere... ", terminator: "")
        fflush(stdout)
        _ = readLine()
        Browser.stop(profile.braveDir)  // robo works in the background from now on
        _ = try Browser.ensure(profile.braveDir, downloads: Browser.downloadsDir)
        print("Done: robo's browser runs in the background with those logins.")
        return 0
    } catch {
        Host.warn("robo: \(error)")
        return 1
    }
}
