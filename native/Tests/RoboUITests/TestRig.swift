// The test rig shared by WindowTests, AppTests, TypedReplyTests and PetTests: a fake Hermes, ear, watcher and
// health poll, a clock, fake displays and openers, in a temp home. Nothing here puts a window on the real
// desktop: the panel is built but never ordered front.
import AppKit
import Foundation
import RoboCore
import RoboSystem
import RoboVoice
@testable import RoboUI

/// Let the main actor go (timers, the bridge's hops and the worker's results run meanwhile) until `until`
/// holds. A test runs inside a main-queue block, so spinning the run loop from it would never run the hops.
@MainActor func pump(_ until: @autoclosure () -> Bool = false, timeout: Double = 5) async -> Bool {
    let end = Date(timeIntervalSinceNow: timeout)
    while Date() < end {
        try? await Task.sleep(for: .milliseconds(10))
        if until() { return true }
    }
    return false
}

/// A latch that lets one waiter through per `signal()` (Python's Event that is cleared after each wait).
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty { tokens += 1; return nil }
            return waiters.removeFirst()
        }
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { c in
            let go = lock.withLock { () -> Bool in
                if tokens > 0 { tokens -= 1; return true }
                waiters.append(c)
                return false
            }
            if go { c.resume() }
        }
    }
}

/// Hermes with a script: events, and `.wait` to hold the run until `gate.signal()`.
final class FakeHermes: HermesAPI, @unchecked Sendable {
    enum Step { case event(Event), wait }
    private let lock = NSLock()
    private var _script: [Step]
    private var _asked: [(text: String, session: String)] = []
    private var _stopped: [String] = []
    private var _approved: [(run: String, choice: ApprovalChoice)] = []
    let gate = Gate()
    var fail: Error?
    var beforeStart: Gate?  // holds the run between "asked" and "started"
    var onAsk: (() -> Void)?  // what Hermes does to the machine while it works (writes files)

    init(_ script: [Step] = [], fail: Error? = nil) {
        _script = script
        self.fail = fail
    }

    var script: [Step] {
        get { lock.withLock { _script } }
        set { lock.withLock { _script = newValue } }
    }
    var asked: [(text: String, session: String)] { lock.withLock { _asked } }
    var stopped: [String] { lock.withLock { _stopped } }
    var approved: [(run: String, choice: ApprovalChoice)] { lock.withLock { _approved } }

    func ask(_ text: String, sessionId: String, started: (@Sendable (String) -> Void)?) -> AsyncThrowingStream<Event, Error> {
        lock.withLock { _asked.append((text, sessionId)) }
        onAsk?()
        let steps = script, fail = fail, before = beforeStart, gate = gate
        return AsyncThrowingStream { out in
            let task = Task {
                if let fail { out.finish(throwing: fail); return }
                if let before { await before.wait() }
                started?("run_1")
                for step in steps {
                    switch step {
                    case .event(let e): out.yield(e)
                    case .wait: await gate.wait()
                    }
                }
                out.finish()
            }
            out.onTermination = { _ in task.cancel() }
        }
    }

    func stop(_ runId: String) async throws { lock.withLock { _stopped.append(runId) } }
    func approve(_ runId: String, _ choice: ApprovalChoice) async throws { lock.withLock { _approved.append((runId, choice)) } }
}

final class FakeEar: Ear {
    let onWake: () -> Void, onText: (String) -> Void, onNote: (String) -> Void
    let ok: Bool
    var now = 0, follow = 0.0, stops = 0
    var stopped: Bool { stops > 0 }
    var running = true, ready = true

    init(_ w: @escaping () -> Void, _ t: @escaping (String) -> Void, _ n: @escaping (String) -> Void, ok: Bool = true) {
        (onWake, onText, onNote, self.ok) = (w, t, n, ok)
    }
    func start() -> Bool { ok }
    func listenNow() { now += 1 }
    func followUp(seconds: Double) { follow = seconds }
    func stop(wait: Double) { stops += 1 }
}

final class FakeWatcher: Watching {
    var started = false, stopped = false, paused = false
    func start() { started = true }
    func stop() { stopped = true }
    func pause(_ paused: Bool) { self.paused = paused }
}

final class FakePoller: Polling {
    let url: String, onState: @Sendable (HealthState) -> Void
    var started = 0, poked = 0, stopped = 0
    init(_ url: String, _ onState: @escaping @Sendable (HealthState) -> Void) { (self.url, self.onState) = (url, onState) }
    func start() { started += 1 }
    func poke() { poked += 1 }
    func stop() { stopped += 1 }
}

/// The monotonic clock of the window: frozen until a test moves it, so no test depends on how fast the
/// machine is (the timers of a test fire on a frozen clock and change nothing; `Rig.step` moves time).
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 1000.0
    func now() -> Double { lock.withLock { seconds } }
    func advance(_ by: Double) { lock.withLock { seconds += by } }
}

/// What the card shows, read from its own views.
extension CardView {
    var heardShown: String { quote.text.textView.string }
    var followUpShown: Bool { !quote.followUp.isHidden }
    var statusShown: String { statusRow.label.text }
    var dotsShown: Bool { !statusRow.dots.isHidden }
    var footerShown: String { footer.text }
    var approvalShown: String? { approval.isHidden ? nil : approval.well.text }
    var caretShown: (show: Bool, on: Bool) { (!caret.isHidden, caret.on) }
}

/// One window with everything around it faked, in a temp home.
@MainActor final class Rig {
    nonisolated(unsafe) static let day = CalendarDay(year: 2026, month: 10, day: 11)!
    /// One display, 1440x900 with a 25 pt menu bar on top (AppKit coordinates).
    static let single = [Display(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                 visible: CGRect(x: 0, y: 0, width: 1440, height: 875))]

    /// /var/folders is a link to /private/var, and the folder listing returns the target: use that one
    /// (Foundation's resolvingSymlinksInPath would strip /private again).
    let dir: URL = {
        let tmp = FileManager.default.temporaryDirectory
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let real = realpath(tmp.path, &buffer) == nil ? tmp : URL(fileURLWithPath: String(cString: buffer))
        return real.appendingPathComponent("robo-ui-\(UUID().uuidString)")
    }()
    let hermes: FakeHermes
    let clock = TestClock()
    var displays = Rig.single
    var pointer = CGPoint(x: 100, y: 100)  // AppKit coordinates
    var files: [URL] = [], notes: [(url: URL, front: Bool)] = []
    var typers: [TypePanel] = [], ears: [FakeEar] = [], pollers: [FakePoller] = []
    var terminated = false
    /// The app that had the keyboard before robo took it, whether robo's app is active, who got it back.
    var frontmost: NSRunningApplication? = NSWorkspace.shared.runningApplications.first {
        $0.processIdentifier != getpid() && $0.activationPolicy == .regular
    }
    var appActive = true
    var activated: [NSRunningApplication] = []
    var window: RoboWindow!
    var win: RoboWindow { window }
    var digest: DigestClock
    var theme: URL { dir.appendingPathComponent("theme.json") }
    var ear: FakeEar { ears[0] }
    var out: URL { dir.appendingPathComponent("Robo") }
    var vault: URL { dir.appendingPathComponent("Vault") }

    /// `cps` is the typing speed of the theme (0 = at once); `digestDue` leaves today's digest to be asked.
    init(_ script: [FakeHermes.Step] = [], fail: Error? = nil, cps: Double = 0, tokens: String = "", digestDue: Bool = false,
         listener: Bool = true, micOK: Bool = true, watcher: Watching? = nil, health: String = "", persona: String = "",
         today: @escaping () -> CalendarDay = { Rig.day }, network: @escaping () -> Bool = { true },
         watchPaused: Bool = false) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        hermes = FakeHermes(script, fail: fail)
        digest = DigestClock(path: dir.appendingPathComponent("state.json"))
        if !digestDue { try? digest.mark(Rig.day) }
        try? "{\"tokens\": {\"cps\": \(cps)\(tokens)}}".write(to: theme, atomically: true, encoding: .utf8)
        if watchPaused { FileManager.default.createFile(atPath: dir.appendingPathComponent("watch.paused").path, contents: nil) }
        var m = Machine(home: dir)
        m.clock = { [clock] in clock.now() }
        m.themeFile = theme
        m.vaultDir = vault
        m.outputDir = out
        m.watchPausedFile = dir.appendingPathComponent("watch.paused")
        m.displays = { [weak self] in self?.displays ?? Rig.single }
        m.pointer = { [weak self] in self?.pointer ?? .zero }
        m.openFile = { [weak self] in self?.files.append($0) }
        m.openNote = { [weak self] url, front in self?.notes.append((url, front)) }
        m.showTyper = { [weak self] in self?.typers.append($0) }
        m.terminate = { [weak self] in self?.terminated = true }
        m.focus = Focus(frontmost: { [weak self] in self?.frontmost }, appIsActive: { [weak self] in self?.appActive ?? false },
                        activate: { [weak self] in self?.activated.append($0) })
        window = RoboWindow(
            hermes: hermes, digest: digest, persona: persona, today: today, network: network, watchWake: false,
            listener: listener ? { [unowned self] w, t, n in
                let e = FakeEar(w, t, n, ok: micOK)
                self.ears.append(e)
                return e
            } : nil,
            watcher: watcher, health: health, poller: { [unowned self] url, on in
                let p = FakePoller(url, on)
                self.pollers.append(p)
                return p
            }, machine: m)
    }

    private var steps = 0

    /// One 33 ms step of time, as the typing timer would take it, with the 100 ms ticker every third step.
    func step() {
        clock.advance(1.0 / 30)
        if window.revealer != nil { window.reveal() }
        steps += 1
        if steps % 3 == 0 { window.tick() }
    }

    /// Step the clock until `until` holds, letting the main actor go between steps so the worker and the
    /// bridge can deliver. Deterministic: how long it takes in real time does not matter.
    func run(until: @autoclosure () -> Bool, steps limit: Int = 3000) async -> Bool {
        for _ in 0..<limit {
            if until() { return true }
            step()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return until()
    }

    /// The panel on screen, far from every display, and the key window (it takes no keyboard from anyone
    /// real: the window never leaves the fake display's plane). False if AppKit would not make it key.
    func makeKeyOffscreen() -> Bool {
        let far = CGRect(x: 100_000, y: 100_000, width: 1440, height: 900)
        displays = [Display(frame: far, visible: far)]
        window.refit()
        window.panel.orderFrontRegardless()
        window.panel.makeKey()
        return window.panel.isKeyWindow
    }

    /// Stop its timers and delete its home.
    func close() {
        window.panel.orderOut(nil)
        window.quit()
        try? FileManager.default.removeItem(at: dir)
    }

    var space: ScreenSpace { window.space }
    var frame: CGRect { window.panel.frame }
    /// Where the pointer is when it is over the middle of the face.
    var overFace: CGPoint {
        let c = window.faceCentre
        return CGPoint(x: c.x, y: space.primaryHeight - c.y)
    }
    /// The face's middle, as AppKit coordinates.
    var faceMiddle: CGPoint { overFace }
}

/// The user's real layout, in AppKit coordinates: the main 2560x1440 display at the origin with a 25 pt
/// menu bar and a 70 pt Dock, and the built-in 1800x1169 display to its LEFT, shorter, with a 37 pt menu bar
/// (in top-left coordinates it sits at (-1800, 271)).
let mainDisplay = Display(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                           visible: CGRect(x: 0, y: 70, width: 2560, height: 1345))
let builtInDisplay = Display(frame: CGRect(x: -1800, y: 0, width: 1800, height: 1169),
                              visible: CGRect(x: -1800, y: 0, width: 1800, height: 1132))
let userLayout = [mainDisplay, builtInDisplay]
