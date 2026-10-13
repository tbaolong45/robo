// The animated face: port of FaceWidget in src/robo/face/widget.py. It repaints at a rate that follows
// the activity; the painting itself is FaceRender.
import AppKit
import RoboCore

/// What the mouse did on the face; the window reads the pointer itself (see `RoboWindow`).
enum FaceMouse { case press, drag, release, rightPress }

final class FaceView: NSView {
    static let size = CGSize(width: 128, height: 96)  // FACE: the floating face

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

    let radius: CGFloat  // > 0: a rounded screen, transparent outside
    let anim: Animator
    let clock: () -> Double
    var goal = FaceParams.target(.idle, "neutral")
    private(set) var activity = Activity.idle
    private(set) var emotion = "neutral"
    private(set) var talking = false
    var hueFn: ((_ activity: String, _ emotion: String, _ base: Double) -> Double)?
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

    init(radius: CGFloat = 22, seed: UInt64? = nil,
                clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.radius = radius
        self.clock = clock
        anim = Animator(seed: seed)
        t0 = clock()
        last = t0
        params = anim.step(goal, dt: 0, talking: false, now: 0)
        super.init(frame: NSRect(origin: .zero, size: FaceView.size))
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

    /// Dress the face for a theme: `hue(activity, emotion, base)` gives the hue this state has in the theme
    /// (`Themes.hueFor`), `bg` the screen's (centre, edge) colours. nil, nil is the face as it always was.
    /// `snap` skips the 0.3 s sweep to the new hue (at start-up).
    func setTheme(hue: ((_ activity: String, _ emotion: String, _ base: Double) -> Double)?,
                         bg: (RGBA, RGBA)?, snap: Bool = false) {
        hueFn = hue
        self.bg = bg
        setState(activity: activity, emotion: emotion, talking: talking)
        if snap {
            anim.x?[\.hue] = goal.hue
            anim.v[\.hue] = 0
            params.hue = goal.hue
        }
        needsDisplay = true
    }

    /// Called all the time (every tick of the window): the timer restarts only when the rate changes.
    func setState(activity: Activity, emotion: String, talking: Bool = false) {
        self.activity = activity
        self.emotion = emotion
        self.talking = talking
        var g = FaceParams.target(activity, emotion)
        if let hueFn { g.hue = hueFn(activity.rawValue, emotion, g.hue) }
        goal = g
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
        if radius > 0 {
            ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
        }
        FaceRender.render(ctx, rect: bounds, params: params, t: last - t0, bg: bg)
    }

    override func mouseDown(with event: NSEvent) { onMouse?(.press) }
    override func mouseDragged(with event: NSEvent) { onMouse?(.drag) }
    override func mouseUp(with event: NSEvent) { onMouse?(.release) }
    override func rightMouseDown(with event: NSEvent) { onMouse?(.rightPress) }
}
