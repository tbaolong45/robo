// The app itself: the delegate that runs the cleanup on any way of quitting, the dev switches, and `RoboApp.run`.
import AppKit
import RoboCore
import RoboSystem
import RoboVoice

/// The dev switches, read once at start: ROBO_NO_VOICE=1 (no microphone), ROBO_NO_WATCH=1 (no activity
/// watching and no ledger), ROBO_HERMES_URL (another gateway: robo's own Brave is then left alone, it is
/// the live gateway's). ROBO_WALL_OFFSET=<seconds, may be negative> is read by `Machine` and shifts its wall clock, so a demo can
/// bring a deadline of the nudges near without waiting; it also shifts the "files made since" and the usage day, so it is for a
/// test copy and never the live profile. ROBO_RADAR_NOW=1 (also read by `Machine`) lets the first run of the daily radar after launch
/// ignore the once-a-day and the 07:00 rules, so a test copy can look at the digest at once; it reads and writes the vault's `Radar/`
/// folder and downloads from the public sources, so use it with a throwaway HOME.
public struct DevSwitches: Equatable {
    public var noVoice: Bool, noWatch: Bool, otherGateway: Bool

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        noVoice = environment["ROBO_NO_VOICE"] == "1"
        noWatch = environment["ROBO_NO_WATCH"] == "1"
        otherGateway = !(environment["ROBO_HERMES_URL"] ?? "").isEmpty
    }
}

/// Logout, the Dock and Apple Events end an app through `terminate`, which would skip the window's cleanup (a
/// request still running on Hermes would stay running): ask the window first and finish when it is done.
final class RoboAppDelegate: NSObject, NSApplicationDelegate {
    let window: RoboWindow
    init(_ window: RoboWindow) { self.window = window }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        window.shouldTerminate { sender.reply(toApplicationShouldTerminate: true) }
    }
}

public enum RoboApp {
    /// The main menu: robo's own item and Edit. It is never on screen (the app is an accessory) but its key
    /// equivalents are what turn Cmd-V into paste: in the Type window.
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
        let profile = HermesProfile(env: environment)
        let dev = DevSwitches(environment: environment)
        let connection: (url: String, key: String)
        do {
            connection = try profile.clientConnection(ensureBrowser: { dir in dev.otherGateway ? true : try Browser.ensure(dir) })
        } catch {
            Host.warn("robo: \(error)")
            return 1
        }
        var watcher: Watching?
        if !dev.noWatch {
            do {
                try ActivityLog.ensureLedger()
                watcher = ActivityWatcher(store: try ActivityStore())
            } catch {
                Host.warn("robo: activity watching is off: \(error)")
            }
        }
        let app = NSApplication.shared
        app.mainMenu = mainMenu()
        app.setActivationPolicy(.accessory)  // no Dock icon and no menu bar: a pet, not a program
        let hotkey = Hotkey()  // Ctrl+Q wakes robo; if the system refuses it, robo wakes by name as before
        let byKey = !dev.noVoice && hotkey.register()
        let window = RoboWindow(
            hermes: HermesClient(baseURL: connection.url, key: connection.key),
            digest: DigestClock(path: dataDir.appendingPathComponent("robo_state.json")),
            persona: profile.personaStamp(),
            listener: dev.noVoice ? nil : { onWake, onText, onNote in
                Listener(onWake: onWake, onText: onText, onNote: onNote, nameWake: !byKey)
            },
            watcher: watcher, health: connection.url, hotkey: byKey ? hotkey : nil, machine: Machine(home: profile.home))
        let delegate = RoboAppDelegate(window)
        app.delegate = delegate
        window.show()
        withExtendedLifetime((window, delegate)) { app.run() }
        return 0
    }

    /// <checkout>/data: the digest date, shared with the Python build until the cutover.
    static var dataDir: URL {
        URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("data")
    }
}
