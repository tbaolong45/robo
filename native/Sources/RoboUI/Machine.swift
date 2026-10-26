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

/// The one fetcher of the app: it remembers the ETags between refreshes.
private let calendarFetcher = CalendarFetcher()

/// Everything the window reaches the machine through. `init(home:)` is the real one.
struct Machine {
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }  // monotonic seconds; stops while the Mac sleeps
    /// Wall time, for the times of files robo made and for the nudges (a deadline does not wait for the Mac to wake). The real one
    /// adds ROBO_WALL_OFFSET (seconds, may be negative) so a demo can bring a deadline near; it shifts everything that reads
    /// `wall`, so it is for a test copy and not for the live profile.
    var wall: () -> Double = { Date().timeIntervalSince1970 }
    var zone: TimeZone = .autoupdatingCurrent  // the user's: the nudge slots (09:00, 13:00, 19:00), quiet hours and "tomorrow"
    /// The user is away from the Mac: the screen is locked or there has been no input for `awayS`. No nudge shows then.
    var userAway: () -> Bool = { ActivityLog.macLocked() || ActivityLog.macIdle() > Machine.awayS }
    /// The calendar links' bodies, fetched now (any thread). The real one reads `calendars.json` of robo's data folder; the rig
    /// replaces it, so no test reads that folder.
    var calendarBodies: @Sendable () async -> CalendarBodies = {
        await CalendarSources(store: FileSecretStore(dir: ActivityLog.dataDir)).fetchAll(using: calendarFetcher)
    }
    /// The daily radar (Radar.swift): on or off (the rig turns it off, so no test reads a vault or the network), how it downloads (given
    /// the cache folder and the hosts of the feeds in the user's profile; the rig replaces it), and ROBO_RADAR_NOW=1 (a test copy only:
    /// the first run after launch ignores the once-a-day and the 07:00 rules).
    var radarOn = true
    var radarNow = false
    var radarFetcher: @Sendable (_ cacheDir: URL, _ extraHosts: Set<String>) -> RadarFetching = { RadarFetcher(cacheDir: $0, extraHosts: $1) }
    /// The LMS posts scan (Scout.swift): the Moodle address when the scan may run (the profile has one AND `robo setup` installed the
    /// school-posts skill), else nil. The real one reads the Hermes profile (read only); the rig answers nil, so no test reads it.
    var postsMoodle: () -> String? = { nil }
    var confirmLink: (URL, String) -> Bool = BoxTextView.askToOpen  // the same alert as a link in a reply
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    static let awayS = 300.0
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
    var nudgeDir: URL  // agenda.json, nudges.json and reminders.json
    var studyFile: URL  // the study ledger: exams and "snooze nudges until"
    var dailyTokens = 0  // ROBO_DAILY_TOKENS, else the number in `daily_tokens` of robo's data folder (set in `init`); 0 = no cap
    var showTyper: (TypePanel) -> Void = { $0.present() }
    /// The chat window (Chat.swift): on or off (the rig turns it off, so every test of the pet's card stays as it is; the chat's tests
    /// turn it on), how it is put on screen (the panel and the usable area of the main display: it opens in the middle of it) and how
    /// its text box takes the keyboard. The rig records both and shows nothing.
    var chatOn = true
    var showChat: (ChatPanel, CGRect) -> Void = { $0.present(on: $1) }
    /// The light blur over the main display while Robo is called (BlurVeil.swift): on or off, and the display's frame (AppKit coordinates).
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

    init(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let offset = environment["ROBO_WALL_OFFSET"].flatMap(Double.init), offset.isFinite {
            wall = { Date().timeIntervalSince1970 + offset }
        }
        // ROBO_NUDGE_PRESENT=1 (a demo/test copy only): the user counts as present however long the Mac has been idle, so a nudge
        // can be looked at at night.
        if environment["ROBO_NUDGE_PRESENT"] == "1" { userAway = { false } }
        radarNow = environment["ROBO_RADAR_NOW"] == "1"
        dailyTokens = Usage.cap(environment, file: ActivityLog.dataDir.appendingPathComponent("daily_tokens"))
        let profile = HermesProfile(home: home, env: environment)
        postsMoodle = { Setup.postsMoodle(profile) }
        outputDir = home.appendingPathComponent("Robo")
        vaultDir = Vault.dir(home: home)
        themeFile = Themes.configPath()
        watchPausedFile = ActivityLog.dataDir.appendingPathComponent("watch.paused")
        receiptsFile = ActivityLog.dataDir.appendingPathComponent("receipts.jsonl")
        usageFile = ActivityLog.dataDir.appendingPathComponent("usage.jsonl")
        nudgeDir = ActivityLog.dataDir
        studyFile = ActivityLog.ledger
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
