// The app itself: the delegate that runs the cleanup on any way of quitting, the dev switches, and `RoboApp.run`.
import AppKit
import RoboCore
import RoboSystem
import RoboVoice

/// The dev switches, read once at start: ROBO_NO_VOICE=1 (no microphone), ROBO_AGENT_URL (another agent: robo then never starts its
/// own; a dead address such as http://127.0.0.1:9 keeps a test copy away from the live one).
public struct DevSwitches: Equatable {
    public var noVoice: Bool, otherAgent: Bool
    /// ROBO_CHAT_DEMO=1 (a test copy only): the chat window opens at launch with a made-up conversation, so its look over a bright and a
    /// dark backdrop can be checked without an agent.
    public var chatDemo: Bool

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        noVoice = environment["ROBO_NO_VOICE"] == "1"
        otherAgent = !(environment["ROBO_AGENT_URL"] ?? "").isEmpty
        chatDemo = environment["ROBO_CHAT_DEMO"] == "1"
    }
}

/// Logout, the Dock and Apple Events end an app through `terminate`, which would skip the window's cleanup (a
/// request still running on the agent would stay running): ask the window first and finish when it is done. Then the agent
/// service ends, if this app started it.
final class RoboAppDelegate: NSObject, NSApplicationDelegate {
    let window: RoboWindow
    let service: AgentService?
    init(_ window: RoboWindow, service: AgentService?) {
        self.window = window
        self.service = service
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        window.shouldTerminate { sender.reply(toApplicationShouldTerminate: true) }
    }

    func applicationWillTerminate(_ notification: Notification) { service?.stop() }
}

/// The agent's client with the service made sure of before each request: started again if it died (off the main thread, bounded
/// by `AgentService.ensure`), and with no DeepSeek key the request fails at once with the one line that says how to add it. With no
/// service (ROBO_AGENT_URL) it is the client itself.
final class AgentKeeper: AgentAPI {
    let client: AgentAPI
    let service: AgentService?
    let hasKey: () -> Bool

    init(_ client: AgentAPI, service: AgentService?, hasKey: @escaping () -> Bool) {
        self.client = client
        self.service = service
        self.hasKey = hasKey
    }

    func ask(_ text: String, sessionId: String, started: (@Sendable (String) -> Void)?) -> AsyncThrowingStream<Event, Error> {
        guard let service else { return client.ask(text, sessionId: sessionId, started: started) }
        let (client, hasKey) = (client, hasKey)
        return AsyncThrowingStream { out in
            let task = Task {
                guard hasKey() else { return out.finish(throwing: BrainError(AgentHome.noKeyMessage)) }
                await withCheckedContinuation { done in DispatchQueue.global().async { service.ensure(); done.resume() } }
                do {
                    for try await event in client.ask(text, sessionId: sessionId, started: started) { out.yield(event) }
                    out.finish()
                } catch {
                    out.finish(throwing: error)
                }
            }
            out.onTermination = { _ in task.cancel() }
        }
    }

    func stop(_ runId: String) async throws { try await client.stop(runId) }
}

public enum RoboApp {
    /// The main menu: robo's own item and Edit. It is never on screen (the app is an accessory) but its key
    /// equivalents are what turn Cmd-V into paste: in the chat's text box.
    static func mainMenu() -> NSMenu {
        let main = NSMenu()
        for submenu in [NSMenu(title: "Robo"), EditKeys.menu()] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }

    /// The floating robo.
    public static func run(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        let agent = AgentHome(env: environment)
        let dev = DevSwitches(environment: environment)
        let connection: (url: String, key: String)
        do {
            connection = try agent.connection()
        } catch {
            Host.warn("robo: \(error)")
            return 1
        }
        let service = agent.service()
        if !dev.otherAgent && service == nil { Host.warn("robo: uv was not found, so robo's agent cannot be started: run `robo setup`") }
        if let service { DispatchQueue.global().async { service.ensure() } }  // up before the first request, the UI never waits
        let app = NSApplication.shared
        app.mainMenu = mainMenu()
        app.setActivationPolicy(.accessory)  // no Dock icon and no menu bar: a pet, not a program
        let hotkey = Hotkey()  // Ctrl+Q wakes robo; if the system refuses it, robo wakes by name as before
        let byKey = !dev.noVoice && hotkey.register()
        let window = RoboWindow(
            agent: AgentKeeper(AgentClient(baseURL: connection.url, key: connection.key), service: service,
                                hasKey: { agent.hasDeepSeekKey }),
            persona: agent.personaStamp(),
            listener: dev.noVoice ? nil : { onWake, onText, onNote in
                Listener(onWake: onWake, onText: onText, onNote: onNote, nameWake: !byKey)
            },
            health: connection.url, hotkey: byKey ? hotkey : nil, machine: Machine())
        let delegate = RoboAppDelegate(window, service: service)
        app.delegate = delegate
        window.show()
        if dev.chatDemo { window.demoChat() }
        withExtendedLifetime((window, delegate)) { app.run() }
        return 0
    }
}
