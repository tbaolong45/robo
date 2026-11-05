// Robo's own agent (`robo-agent`, a local Python service that serves the run API `AgentClient` speaks): where its files live,
// how the app reaches it, `robo key`, and keeping the service running while the app runs.
//
// Everything is in `R = ~/.local/share/robo/agent/` (0700): `config.json` (written by `robo setup`, see `Setup.writeConfig`) and
// one-line key files (0600): `api_key` (Anthropic), `supermemory_key` (optional) and `server_key` (the bearer the app sends).
// No key is ever printed, logged or put in an error.
import CryptoKit
import Foundation
import Security

/// Robo's agent files for one user: `home` is the user's home, `env` the environment (`ROBO_AGENT_URL`). Tests pass a temp home;
/// only the CLI entry points and the app use the real one.
public struct AgentHome {
    public static let defaultPort = 8765
    public static let defaultModel = "claude-sonnet-5-5"
    /// What `robo key set <name>` writes, by name.
    public static let keyFiles = ["anthropic": "api_key", "supermemory": "supermemory_key"]
    public static let serverKeyFile = "server_key"
    /// The one line the card or the chat shows when the agent cannot work without the user's Anthropic key.
    public static let noKeyMessage = "Robo's agent has no Anthropic API key yet: run `robo key set anthropic` in Terminal."

    public var home: URL
    public var env: [String: String]

    /// Without `home`, `$HOME` (Foundation's own home call ignores it).
    public init(home: URL? = nil, env: [String: String] = ProcessInfo.processInfo.environment) {
        self.env = env
        let fallback = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        self.home = home ?? URL(fileURLWithPath: fallback)
    }

    public var dir: URL { home.appendingPathComponent(".local/share/robo/agent") }
    public var configFile: URL { dir.appendingPathComponent("config.json") }
    public func keyFile(_ name: String) -> URL { dir.appendingPathComponent(name) }
    /// The service's stdout and stderr.
    public var logFile: URL { home.appendingPathComponent("Library/Logs/Robo/agent.log") }
    /// Robo's Brave (school logins). It stays where the Hermes build kept it, so the logins survive the switch.
    public var braveDir: URL { home.appendingPathComponent(".hermes/profiles/robo/brave") }
    /// The PATH the service runs with (launchd gives the app almost none): where uv and its Python live.
    public var servicePATH: String { Host.path(home.appendingPathComponent(".local/bin")) + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" }

    /// ROBO_AGENT_URL: another agent (a dead address for a test copy). The app then never starts the service, nor robo's Brave.
    public var otherAgent: Bool { !(env["ROBO_AGENT_URL"] ?? "").isEmpty }

    // MARK: config.json

    /// config.json as an object; empty when missing. Throws when it exists but is not a JSON object (setup must not overwrite it).
    func readConfig() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: configFile) else { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SetupError("\(Host.path(configFile)) is not a JSON object: fix or remove it, then run `robo setup` again.")
        }
        return object
    }

    private var config: [String: Any] { (try? readConfig()) ?? [:] }

    public var port: Int { (config["port"] as? Int).flatMap { (1...65535).contains($0) ? $0 : nil } ?? Self.defaultPort }

    /// The model the agent runs, for the card's header chip.
    public var model: String { (config["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultModel }

    /// The Moodle address, normalised as setup stores it, or nil (unset, or not an https address). It goes into Brave's command line
    /// (`robo signin`) and gates the LMS posts scan.
    public var moodle: String? {
        guard let url = config["moodle_url"] as? String, !url.isEmpty else { return nil }
        return try? Setup.moodleURL(url)
    }

    // MARK: keys

    /// The key in `file`, trimmed; nil when missing or empty.
    public func readKey(_ file: String) -> String? {
        (try? String(contentsOf: keyFile(file), encoding: .utf8)).map(Host.trimmed).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// One line, 0600, atomically (the folder 0700).
    func writeKey(_ value: String, to file: String) throws {
        try NudgeFiles.atomicWrite(Data((value + "\n").utf8), to: keyFile(file))
    }

    /// 32 bytes from the system's secure generator, base64url without padding.
    static func newServerKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SetupError("no random bytes for the server key") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: the connection

    /// (base URL, server key) for AgentClient; `ROBO_AGENT_URL` overrides the URL (and then a missing key is no error: a dead
    /// address needs none).
    public func connection() throws -> (url: String, key: String) {
        if otherAgent { return (env["ROBO_AGENT_URL"]!, readKey(Self.serverKeyFile) ?? "") }
        guard let key = readKey(Self.serverKeyFile) else { throw SetupError("Robo's agent has no server key yet: run `robo setup` first.") }
        return ("http://127.0.0.1:\(port)", key)
    }

    /// The connection, after making sure robo's Brave is up for school browsing (chat still works without it; school questions will
    /// say so). With `ROBO_AGENT_URL` Brave is left alone.
    public func clientConnection(ensureBrowser: (URL) throws -> Bool = { try Browser.ensure($0, downloads: Browser.downloadsDir) },
                                 warn: (String) -> Void = Host.warn) throws -> (url: String, key: String) {
        let connection = try connection()
        if !otherAgent {
            do { _ = try ensureBrowser(braveDir) } catch let e as BrowserError { warn("robo: \(e)") }
        }
        return connection
    }

    /// Short hash of the agent's SOUL.md and skills (`<agent>/SOUL.md`, `<agent>/skills/**/SKILL.md`).
    ///
    /// A session's system prompt is built once, so robo starts a new session whenever this changes; otherwise a running day's chat
    /// would never see an updated persona or skill.
    public func personaStamp(agentDir: URL? = nil) -> String {
        let agentDir = agentDir ?? Setup.checkout.appendingPathComponent("agent")
        let skills = Setup.files(under: agentDir.appendingPathComponent("skills")).filter { $0.last == "SKILL.md" }
        var h = SHA256()
        for rel in ([["SOUL.md"]] + skills.map { ["skills"] + $0 }).sorted(by: Setup.pathOrder) {
            guard let data = FileManager.default.contents(atPath: rel.reduce(agentDir, { $0.appendingPathComponent($1) }).path)
            else { continue }
            h.update(data: Data(rel.joined(separator: "/").utf8) + [0] + data + [0])
        }
        return h.finalize().prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: the service

    /// `uv run --project <checkout> robo-agent serve`, from config's `uv_path` (else uv where the service PATH has it); nil without uv.
    public func serviceCommand(checkout: URL? = nil) -> [String]? {
        let checkout = checkout ?? Setup.checkout
        guard let uv = (config["uv_path"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? Setup.findUV(self) else { return nil }
        return [uv, "run", "--project", Host.path(checkout), "robo-agent", "serve"]
    }

    /// The service the app keeps up, or nil: ROBO_AGENT_URL points elsewhere (never start one then), or uv is not there.
    public func service(launch: @escaping AgentService.Launch = AgentService.launch) -> AgentService? {
        guard !otherAgent, let command = serviceCommand() else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = servicePATH
        environment["HOME"] = Host.path(home)
        environment.removeValue(forKey: "ROBO_AGENT_URL")
        let health = "http://127.0.0.1:\(port)/health"
        return AgentService(command: command, environment: environment, log: logFile,
                            healthy: { Host.httpStatus(health, timeout: 1.5) == 200 }, launch: launch)
    }

    /// Is the user's Anthropic key there?
    public var hasAnthropicKey: Bool { readKey(Self.keyFiles["anthropic"]!) != nil }
}

/// A running service process: `Process`, or a fake in tests.
public protocol AgentProcess: AnyObject {
    var isRunning: Bool { get }
    func terminate()
}
extension Process: AgentProcess {}

/// Keeps robo's agent up while the app runs: `ensure()` starts it when `/health` does not answer and waits (bounded) until it does.
/// It never starts a second one while its own is still running, starts it again when its own has died, and `stop()` ends only the
/// one it started (an agent that was already running when robo came is left alone).
public final class AgentService: @unchecked Sendable {
    public typealias Launch = (_ argv: [String], _ environment: [String: String], _ log: URL) throws -> AgentProcess

    let command: [String]
    let environment: [String: String]
    let log: URL
    private let healthy: () -> Bool
    private let launch: Launch
    private let wait: Double
    private let sleep: (Double) -> Void
    private let ensuring = NSLock()  // one ensure at a time: a second caller waits for the first one's answer
    private let lock = NSLock()  // guards `child` (stop() must not wait out an ensure)
    private var child: AgentProcess?

    public init(command: [String], environment: [String: String], log: URL, healthy: @escaping () -> Bool,
                launch: @escaping Launch = AgentService.launch, wait: Double = 30,
                sleep: @escaping (Double) -> Void = Thread.sleep(forTimeInterval:)) {
        self.command = command
        self.environment = environment
        self.log = log
        self.healthy = healthy
        self.launch = launch
        self.wait = wait
        self.sleep = sleep
    }

    /// True when the agent answers. Blocks up to `wait` seconds: call it off the main thread.
    @discardableResult
    public func ensure() -> Bool {
        ensuring.withLock {
            if healthy() { return true }
            let running = lock.withLock { child?.isRunning == true }
            if !running {
                do {
                    let started = try launch(command, environment, log)
                    lock.withLock { child = started }
                } catch {
                    Host.warn("robo: could not start robo's agent (\(command.first ?? "")): \(error.localizedDescription)")
                    return false
                }
            }
            for _ in 0..<max(1, Int(wait / 0.5)) {
                sleep(0.5)
                if healthy() { return true }
                if lock.withLock({ child?.isRunning != true }) { return false }  // it died: see the log; the next ask tries again
            }
            return false
        }
    }

    /// End the service if this app started it and it still runs.
    public func stop() {
        lock.withLock {
            if child?.isRunning == true { child?.terminate() }
            child = nil
        }
    }

    /// Start `argv` with `environment`, stdout and stderr appended to `log` (0600, its folder made), stdin /dev/null.
    public static let launch: Launch = { argv, environment, log in
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let out = try FileHandle(forWritingTo: log)
        defer { try? out.close() }  // the child keeps its own copy
        out.seekToEndOfFile()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = out
        try p.run()
        return p
    }
}

// MARK: - `robo key`

public enum Keys {
    static let usage = "usage: robo key set {anthropic,supermemory} | robo key status\n"
        + "  set: reads the key from the terminal (not shown) or from stdin, never from the command line"

    /// A key as typed or piped: trimmed, then one run of printable non-space ASCII of at most 1024 characters; nil otherwise.
    static func clean(_ raw: String) -> String? {
        let key = Host.trimmed(raw)
        guard !key.isEmpty, key.utf8.count <= 1024, key.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { return nil }
        return key
    }

    /// From the terminal with echo off when stdin is one, else everything on stdin.
    public static func readSecret() -> String? {
        guard isatty(0) != 0 else { return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
        var buffer = [CChar](repeating: 0, count: 2048)
        defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        guard let line = readpassphrase("Paste the key (it is not shown), then Enter: ", &buffer, buffer.count, RPP_REQUIRE_TTY) else { return nil }
        return String(cString: line)
    }
}

/// `robo key set NAME` / `robo key status` (`args` are what follows `key`); the exit code. Nothing it prints holds a key.
public func runKey(_ args: [String], agent: AgentHome = AgentHome(), readSecret: () -> String? = Keys.readSecret,
                   out: (String) -> Void = { print($0) }, err: (String) -> Void = Host.warn) -> Int32 {
    switch args {
    case ["status"]:
        for (name, file) in AgentHome.keyFiles.sorted(by: { $0.key < $1.key }) + [("server", AgentHome.serverKeyFile)] {
            out("\(name): \(agent.readKey(file) == nil ? "not set" : "set")")
        }
        return 0
    case let a where a.count == 2 && a[0] == "set" && AgentHome.keyFiles[a[1]] != nil:
        guard let key = readSecret().flatMap(Keys.clean) else {
            err("robo: no key read (one line of letters, digits and symbols, no spaces): nothing was saved")
            return 1
        }
        do {
            try agent.writeKey(key, to: AgentHome.keyFiles[a[1]]!)
        } catch {
            err("robo: could not save the \(a[1]) key in \(Host.path(agent.dir))")
            return 1
        }
        out("saved your \(a[1]) key (\(Host.path(agent.keyFile(AgentHome.keyFiles[a[1]]!))), readable only by you)")
        return 0
    default:
        err(Keys.usage)
        return 2
    }
}
