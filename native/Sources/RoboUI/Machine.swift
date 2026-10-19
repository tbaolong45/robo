// What the window reaches the outside world through: Hermes, the microphone, the activity watcher, the
// health poll (protocols with the real class as the conforming type) and `Machine` (displays, pointer,
// clock, files, the Type window). The tests pass fakes for every one of them.
import AppKit
import RoboCore
import RoboSystem
import RoboVoice

/// What the window needs from Hermes: `HermesClient`, or a fake in tests.
protocol HermesAPI: AnyObject {
    func ask(_ text: String, sessionId: String, started: (@Sendable (String) -> Void)?) -> AsyncThrowingStream<Event, Error>
    func stop(_ runId: String) async throws
    func approve(_ runId: String, _ choice: ApprovalChoice, requestId: String) async throws
}
extension HermesClient: HermesAPI {}

/// The microphone side: `Listener`, or a fake.
protocol Ear: AnyObject {
    var running: Bool { get }
    var ready: Bool { get }
    var handsFree: Bool { get }  // the text being delivered was spoken in a key-less follow-up window
    func start() -> Bool
    func listenNow()
    func hold()
    func release()
    func followUp(seconds: Double)
    func stop(wait: Double)
}
extension Listener: Ear {}

/// Builds the ear with the window's three callbacks (called from the listener's thread).
typealias EarFactory = (_ onWake: @escaping () -> Void, _ onText: @escaping (String) -> Void,
                               _ onNote: @escaping (String) -> Void) -> Ear

/// Activity watching: `ActivityWatcher`, or a fake.
protocol Watching: AnyObject {
    var paused: Bool { get }
    func pause(_ paused: Bool)
    func start()
    func stop()
}
extension ActivityWatcher: Watching {}

/// The gateway health poll: `HealthPoller`, or a fake.
protocol Polling: AnyObject {
    func start()
    func poke()
    func stop()
}
extension HealthPoller: Polling {}

typealias PollerFactory = (_ url: String, _ onState: @escaping @Sendable (HealthState) -> Void) -> Polling

/// Everything the window reaches the machine through. `init(home:)` is the real one.
struct Machine {
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }  // monotonic seconds
    var wall: () -> Double = { Date().timeIntervalSince1970 }  // for the times of files robo made
    var displays: () -> [Display] = Display.current
    var pointer: () -> CGPoint = { NSEvent.mouseLocation }  // AppKit coordinates
    var openFile: (URL) -> Void
    var openNote: (_ note: URL, _ front: Bool) -> Void
    var outputDir: URL  // what robo makes (diagrams, pages, documents); see SOUL.md
    var vaultDir: URL
    var themeFile: URL
    var watchPausedFile: URL  // exists = watching paused
    var receiptsFile: URL  // what robo-guard recorded of Hermes' state-changing steps (the footer's "✓ sent")
    var usageFile: URL  // one line per finished run: tokens, seconds, steps
    var dailyTokens = Usage.cap(ProcessInfo.processInfo.environment)  // ROBO_DAILY_TOKENS; 0 = no cap
    var showTyper: (TypePanel) -> Void = { $0.present() }
    var terminate: () -> Void = { NSApp.terminate(nil) }
    var focus = Focus()
    /// The mean luma (0...1) of the screen behind a rectangle (AppKit coordinates), nil when it cannot be read; `done` runs on the
    /// main thread. And the one-time request for the Screen Recording permission it needs.
    var backdropLuma: (_ rect: NSRect, _ done: @escaping (Double?) -> Void) -> Void = { Backdrop.shared.luma(behind: $0, done: $1) }
    var askScreenAccess: () -> Void = { Backdrop.shared.requestAccess() }
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Whether the system is in dark mode: the card's look while it cannot read what is behind it (it must still pick a light or a
    /// dark card, or the text colour and the glass can disagree).
    var systemDark: () -> Bool = { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    init(home: URL) {
        outputDir = home.appendingPathComponent("Robo")
        vaultDir = Vault.dir(home: home)
        themeFile = Themes.configPath()
        watchPausedFile = ActivityLog.dataDir.appendingPathComponent("watch.paused")
        receiptsFile = ActivityLog.dataDir.appendingPathComponent("receipts.jsonl")
        usageFile = ActivityLog.dataDir.appendingPathComponent("usage.jsonl")
        openFile = { try? Host.spawn(["open", $0.path]) }
        openNote = { note, front in try? Vault.openNote(note, home: home, front: front) }
    }
}

/// A repeating timer in the common run loop modes, so it keeps going while a menu or a drag tracks events.
/// `tolerance` (a share of the interval) lets the system fire it together with other wake-ups instead of at its
/// exact instant: every timer of robo has one, an idle pet must cost next to nothing.
func commonTimer(_ seconds: Double, tolerance share: Double = 0.1, _ fire: @escaping () -> Void) -> Timer {
    let timer = Timer(timeInterval: seconds, repeats: true) { _ in fire() }
    timer.tolerance = seconds * share
    RunLoop.main.add(timer, forMode: .common)
    return timer
}
