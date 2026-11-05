// The animated face. It repaints at a rate that follows
// the activity; the painting itself is FaceRender.
import AppKit
import RoboCore

/// What the mouse did on the face; the window reads the pointer itself (see `RoboWindow`).
enum FaceMouse { case press, drag, release, rightPress }

final class FaceView: NSView {
    static let size = CGSize(width: 128, height: 128)  // FACE: the floating face, a disc of 112 (FaceRender.disc) and its shadow

    // Repaint interval (ms) per activity: the pet sleeps most of the day and a calm face needs few frames.
    // Everything else (talking mouth 6-9 Hz, listening pulse, ...) runs at `fastMS`. A blink lasts 0.15 s,
    // so 66 ms is the slowest rate that still shows it (2 shut frames); asleep never blinks.
    static let fastMS = 33
    static func frameMS(_ activity: Activity) -> Int {
        switch activity {
        case .idle: return 40
        case .sleepy: return 66
        case .asleep: return 100
        default: return fastMS
        }
    }

    let anim: Animator
    let clock: () -> Double
    var goal = FaceParams.target(.idle, "neutral")
    private(set) var activity = Activity.idle
    private(set) var emotion = "neutral"
    private(set) var talking = false
    var bg: (RGBA, RGBA)?
    private(set) var look: Vec?
    private(set) var params: FaceParams
    private(set) var frameMS = FaceView.frameMS(.idle)
    private(set) var timerStarts = 0  // tests: how often the timer was restarted
    private let t0: Double
    private var last: Double
    private(set) var timer: Timer?
    var onMouse: ((FaceMouse) -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }  // a click works in a non-key window

    init(seed: UInt64? = nil, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        anim = Animator(seed: seed)
        t0 = clock()
        last = t0
        params = anim.step(goal, dt: 0, talking: false, now: 0)
        super.init(frame: NSRect(origin: .zero, size: FaceView.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Robo")
        setAccessibilityHelp("Click to talk to Robo, to stop what it is doing, or to close its answer. Drag to move it; right-click for its menu.")
        startTimer()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { timer?.invalidate() }

    private func startTimer() {
        timer?.invalidate()
        timerStarts += 1
        // half the share of the others: 66 ms is the slowest rate that still shows a blink, so it may not stretch
        timer = commonTimer(Double(frameMS) / 1000, tolerance: 0.05) { [weak self] in self?.tick() }  // keeps ticking while a menu or a drag tracks events
    }

    /// Dress the face for a theme: `bg` is the body's (centre, edge) colours. nil is the face as it always was.
    func setTheme(bg: (RGBA, RGBA)?) {
        self.bg = bg
        needsDisplay = true
    }

    /// Called all the time (every tick of the window): the timer restarts only when the rate changes.
    func setState(activity: Activity, emotion: String, talking: Bool = false) {
        self.activity = activity
        self.emotion = emotion
        self.talking = talking
        goal = FaceParams.target(activity, emotion)
        let ms = FaceView.frameMS(activity)
        if ms != frameMS {
            frameMS = ms
            startTimer()
        }
    }

    /// Point the eyes (see `lookAt`); nil = free glances.
    func setLook(_ look: Vec?) { self.look = look }

    func tick() {
        let now = clock()
        let dt = min(now - last, 0.1)
        last = now
        params = anim.step(goal, dt: dt, talking: talking, now: now - t0, look: look)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        FaceRender.render(ctx, rect: bounds, params: params, t: last - t0, bg: bg)
    }

    override func mouseDown(with event: NSEvent) { onMouse?(.press) }
    override func mouseDragged(with event: NSEvent) { onMouse?(.drag) }
    override func mouseUp(with event: NSEvent) { onMouse?(.release) }
    override func rightMouseDown(with event: NSEvent) { onMouse?(.rightPress) }

    /// VoiceOver's press is a click: a press and a release with no drag between.
    override func accessibilityPerformPress() -> Bool {
        onMouse?(.press)
        onMouse?(.release)
        return true
    }

    /// VoiceOver's "show menu" is the right click.
    override func accessibilityPerformShowMenu() -> Bool {
        onMouse?(.rightPress)
        return true
    }
}
