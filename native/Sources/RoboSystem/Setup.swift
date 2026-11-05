// `robo setup`: robo's agent settings (`AgentHome`: config.json and the server key) and the login item. The agent reads its own
// SOUL.md (`<checkout>/agent/`), so setup installs no templates; the app starts the agent itself (`AgentService`). The ai.robo
// LaunchAgent starts this app's executable, not `uv run`.
import Foundation

public struct SetupError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

public enum Setup {
    static let launchAgentLabel = "ai.robo"  // ~/Library/LaunchAgents/ai.robo.plist starts robo at login

    /// This checkout, wherever it was cloned.
    static let checkout = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Only the bundled app may be started at login: a bare binary (`swift run`, .build/debug/robo) has no
    /// Info.plist, so no NSMicrophoneUsageDescription, and under launchd it is its own TCC client and is killed
    /// at the first microphone access.
    static func requireApp(_ executable: URL) throws {
        guard Host.path(executable).hasSuffix(".app/Contents/MacOS/robo") else {
            throw SetupError("robo must start from its app bundle at login, not from \(Host.path(executable)): "
                             + "run native/bundle.sh and run `robo setup` with the app it builds (build/Robo.app/Contents/MacOS/robo).")
        }
    }

    /// macOS: launchd starts robo at each login.
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

    /// Write `R/config.json`, keeping what is already there: `port` and `model` get a default only when missing; `uv_path` always
    /// names this uv. Keys it does not know stay. The "..." lines of what changed.
    static func writeConfig(_ a: AgentHome, uv: String) throws -> [String] {
        let old = try a.readConfig()
        var config = old
        let defaults: [String: Any] = ["port": AgentHome.defaultPort, "model": AgentHome.defaultModel]
        for (key, value) in defaults where config[key] == nil || config[key] is NSNull { config[key] = value }
        config["uv_path"] = uv
        // -1e999 parses as -infinity, and writing that raises an exception no Swift code can catch
        guard JSONSerialization.isValidJSONObject(config) else {
            throw SetupError("\(Host.path(a.configFile)) holds a value that can't be written back: fix or remove it, then run `robo setup` again.")
        }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if (try? Data(contentsOf: a.configFile)) == data { return [] }
        do { try Host.atomicWrite(data, to: a.configFile) } catch {
            throw SetupError("Could not write \(Host.path(a.configFile)): \(error.localizedDescription)")
        }
        return [old.isEmpty ? "wrote robo's agent settings (\(Host.path(a.configFile)))" : "updated robo's agent settings"]
    }

    /// `robo setup`: the agent's settings and server key, then the LaunchAgent; the "- ..." lines it prints.
    static func report(agent a: AgentHome, executable: URL, project: URL, uv: (AgentHome) -> String? = findUV) throws -> [String] {
        try requireApp(executable)  // before anything is written
        let soul = project.appendingPathComponent("agent/SOUL.md")
        guard Host.exists(soul) else {
            throw SetupError("robo's agent is not in \(Host.path(soul.deletingLastPathComponent())): run robo from the checkout it was built in.")
        }
        guard let uv = uv(a) else {
            throw SetupError("uv is not installed (looked in \(a.servicePATH)): install it (`brew install uv`), then run `robo setup` again.")
        }
        var done = try writeConfig(a, uv: uv)
        if a.readKey(AgentHome.serverKeyFile) == nil {
            try a.writeKey(try AgentHome.newServerKey(), to: AgentHome.serverKeyFile)
            done.append("made the key the app uses with robo's agent")
        }
        done += try launchAgent(home: a.home, executable: executable)
        if !a.hasDeepSeekKey { done.append("next: run `robo key set deepseek` (robo's agent needs your DeepSeek API key)") }
        return (done.isEmpty ? ["already set up, nothing changed"] : done).map { "- \($0)" }
    }
}

/// `robo setup` (`args` are what follows `setup`: none is expected); the exit code.
public func runSetup(_ args: [String], executable: URL? = nil, project: URL? = nil) -> Int32 {
    guard args.isEmpty else {
        Host.warn("usage: robo setup\nrobo: error: unrecognized arguments: \(args.joined(separator: " "))")
        return 2
    }
    do {
        let lines = try Setup.report(agent: AgentHome(),
                                     executable: executable ?? Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
                                     project: project ?? Setup.checkout)
        lines.forEach { print($0) }
        return 0
    } catch {
        Host.warn("robo: \(error)")
        return 1
    }
}
