// What the window reaches the outside world through: the agent, the microphone, the health poll (protocols
// with the real class as the conforming type) and `Machine` (displays, pointer, clock, the chat window). The
// tests pass fakes for every one of them.
import AppKit
import RoboCore
import RoboVoice

/// What the window needs from robo's agent: `AgentClient` (behind `AgentKeeper` in the app), or a fake in tests.
protocol AgentAPI: AnyObject {
    func ask(_ text: String, sessionId: String, started: (@Sendable (String) -> Void)?) -> AsyncThrowingStream<Event, Error>
    func stop(_ runId: String) async throws
}
extension AgentClient: AgentAPI {}

/// The microphone side: `Listener`, or a fake.
protocol Ear: AnyObject {
    var running: Bool { get }
    var ready: Bool { get }
    func start()
    func listenNow()
    func hold()
    func release()
    func followUp(seconds: Double)
    func stop(wait: Double)
}
extension Listener: Ear {}

/// Builds the ear with the window's three callbacks (called from the listener's thread). `onText`'s Bool: the text was spoken in a key-less follow-up window.
typealias EarFactory = (_ onWake: @escaping () -> Void, _ onText: @escaping (String, Bool) -> Void,
                               _ onNote: @escaping (String) -> Void) -> Ear

/// The agent's health poll: `HealthPoller`, or a fake.
protocol Polling: AnyObject {
    func start()
    func poke()
    func stop()
}
extension HealthPoller: Polling {}

typealias PollerFactory = (_ url: String, _ onState: @escaping @Sendable (HealthState) -> Void) -> Polling

/// Everything the window reaches the machine through. `Machine()` is the real one.
struct Machine {
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }  // monotonic seconds; stops while the Mac sleeps
    var displays: () -> [Display] = Display.current
    var pointer: () -> CGPoint = { NSEvent.mouseLocation }  // AppKit coordinates
    var themeFile = Themes.configPath()
    /// The chat window (Chat.swift): on or off (the rig turns it off, so every test of the pet's card stays as it is; the chat's tests
    /// turn it on), how it is put on screen (the panel and the usable area of the main display: it opens in the middle of it) and how
    /// its text box takes the keyboard. The rig records both and shows nothing.
    var chatOn = true
    var showChat: (ChatPanel, CGRect) -> Void = { $0.present(on: $1) }
    /// Whether the chat's text box has the keyboard (the rig answers for it: its panel is never key).
    var chatTyping: (ChatPanel) -> Bool = { $0.inputActive }
    /// The light blur over the main display while Robo listens or the chat's text box has the keyboard (BlurVeil.swift): on or off, and
    /// the display's frame (AppKit coordinates).
    var blurBackground: (Bool, CGRect) -> Void = { on, frame in
        BlurVeil.shared.set(on, over: frame, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    var focusChat: (ChatPanel) -> Void = {
        $0.makeKey()
        $0.chat.focusInput()
    }
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
