// Robo on the desktop: a floating face with a speech card. Port of the window half of src/robo/app.py
// (layout, fit, roaming, dragging, menu, themes, screens); the conversation half is in App.swift.
//
// Everything here runs on the main thread. The machine (displays, pointer, clock, files, the Type window)
// comes in through `Machine`, Hermes, the microphone, the activity watcher and the health poll through
// the protocols below, so the tests drive the whole window with fakes.
import AppKit
import RoboCore
import RoboSystem
import RoboVoice

final class RoboWindow {
    static let digestPrompt = "Give me my school digest for today (use the school digest skill)."
    static let approvalMax = 300  // characters of an approval request (a long command) shown
    static let closeAfter = 20.0  // s a reply stays up after its last letter (longer while the mouse is over it)
    static let typeS = 0.033  // s between typing steps (30 Hz; 0.030 if a slow machine struggles)
    static let solidS = 0.5  // s the caret stays solid after a letter, then it blinks
    static let caretS = 1.6  // s the caret keeps blinking once the reply is all there
    static let openMax = 3  // notes and files opened after one request, together
    static let followUpS = 15.0  // s after the answer is typed when you can reply without saying "robo"
    static let drag = 6.0  // px of movement that turns a click on the face into a drag
    static let fidgets = ["curious", "happy", "playful", "calm"]  // what a bored robo shows now and then
    static let fidgetEvery = 40.0...120.0  // s between those moods while it idles
    static let margin = 4.0, gap = 3.0  // around the card and the face, between them
    static let roamFast = 1.0 / 30, roamSlow = 0.5  // s between roam steps while it moves, and while it rests, is held or sleeps

    let hermes: HermesAPI
    let digest: DigestClock
    let persona: String
    let today: () -> CalendarDay
    let network: () -> Bool
    var machine: Machine
    let watcher: Watching?
    let bridge = Bridge()
    let panel = RoboPanel()
    let card: CardView
    let face: FaceView
    private let root = RootView()
    var typer: TypePanel?

    var theme: Theme
    var themeStamp: Int
    var space: ScreenSpace
    var roamer: Roamer
    var fitDepth = 0
    var mind: Mind
    var tw: Typewriter

    let lock = NSLock()  // busy, runID and cancel are shared with the worker
    var busy = false
    var runID: String?
    var cancel = false
    var sessionID = ""
    var digestDay: CalendarDay?  // the day a running digest counts for
    var autoDigest = false  // that digest started by itself (start-up, wake), not from the menu
    var reply = ""
    var pending = ""  // a question asked during a run, asked when it ends
    var approvals: [(id: String, text: String)] = []  // asks waiting for a click, oldest first (the card shows the first); cleared when the run ends
    var scanned: Made?  // what the worker found robo made, for `ended` (under `lock`)
    var startedAt = 0.0  // when the current request began (files made since then open)
    var runStart = 0.0  // the same moment on the window's clock: "still working" counts from it
    var toolLabel = ""  // what the last tool of this request was doing; stays up while the model thinks between tools
    var listening = false
    var closeAt = 0.0  // when the finished reply's card closes (0 = not scheduled)
    var closeAfter = 0.0  // s the card stays once the reply is typed (0 = until closed)
    var typed = false  // the reply is all on screen (the footer showed, the close timer ran)
    var lastTick = -Double.infinity, lastChar = -Double.infinity, typedAt = -Double.infinity
    var mouth = false  // a letter showed, finished; the mouth moves (tw.revealing, last seen)
    var answeredAt = -Double.infinity  // when the last answer ended (the next question follows up)
    var followDue = false  // a completed answer is being typed: the follow-up window opens when it is all there
    var followUntil = 0.0  // the key-less follow-up window is open until then (the MIC light shows it)
    var link = LedState.unknown, noted = false  // Hermes light; the listener reported a problem
    var press: Vec?  // where the pointer went down on the face
    var dragged = false
    var grabAt = Vec.zero  // where in the window the face was grabbed
    var cursor = Vec.zero, cursorMoved = -Double.infinity  // the pointer, and when it last moved
    var fidgetAt: Double

    var nudge = NudgeModel()  // the agenda, the budget and the card that shows now (Nudges.swift)
    var radar = RadarModel()  // the daily radar: when it last ran, what it already showed, what it offers (Radar.swift)
    var scout = ScoutModel()  // the LMS posts scan: its courses, the run in flight, its failures today (Scout.swift)
    var typerOpen = false  // the Type window is up (a nudge does not break in on it)

    var ear: Ear?
    var poller: Polling?
    var wakeWatcher: WakeWatcher?
    var ticker: Timer?, roamTimer: Timer?, revealer: Timer?
    var shade = Shade()  // what the card does about the backdrop: light over a dark screen, dark over a light one
    var shadeTimer: Timer?  // 30 Hz, only while the shade is turning
    var lastShade = 0.0  // when it last took a step
    var sampleAt = 0.0, sampling = false  // when the card next looks at the backdrop; a look is in flight
    var askedScreen = false  // Screen Recording was asked for (once per launch)
    var screenObserver: NSObjectProtocol?
    var previousApp: NSRunningApplication?  // who had the keyboard before the panel took it
    var idWait = 3.0  // s a run being created is given to get its id before the app ends
    var shutdownStarted = false, shutdownDone = false
    var shutdownWaiters: [() -> Void] = []
    var roamInterval = RoboWindow.roamSlow

    init(hermes: HermesAPI, digest: DigestClock, persona: String = "",
                today: @escaping () -> CalendarDay = { CalendarDay() }, network: (() -> Bool)? = nil,
                watchWake: Bool = true, listener: EarFactory? = nil, watcher: Watching? = nil, health: String = "",
                poller makePoller: PollerFactory? = nil, hotkey: Hotkey? = nil, machine: Machine) {
        self.hermes = hermes
        self.digest = digest
        self.persona = persona
        self.today = today
        self.network = network ?? { Host.httpStatus("https://outlook.office.com", timeout: 3) != nil }
        self.machine = machine
        self.watcher = watcher
        theme = Themes.load(path: machine.themeFile)
        themeStamp = Themes.stamp(path: machine.themeFile)
        let now = machine.clock()
        mind = Mind(now: now)
        tw = Typewriter(Pace(cps: theme.cps))
        fidgetAt = now + Double.random(in: RoboWindow.fidgetEvery)
        card = CardView(theme: theme, hasWatch: watcher != nil, model: Setup.model)
        face = FaceView(radius: 22, clock: machine.clock)

        var displays = machine.displays()
        if displays.isEmpty {  // no display at all: still build the window
            let f = CGRect(x: 0, y: 0, width: 1440, height: 900)
            displays = [Display(frame: f, visible: f)]
        }
        space = ScreenSpace(displays)!
        roamer = Roamer(screens: space.roamArea(displays), size: Vec(FaceView.size.width + 8, FaceView.size.height + 8))

        bridge.window = self
        panel.title = "Robo"
        panel.onEscape = { [weak self] in self?.escape() }
        panel.onBecomeKey = { [weak self] in
            if let app = self?.machine.focus.other() { self?.previousApp = app }
        }
        panel.contentView = root
        root.addSubview(card)
        root.addSubview(face)
        card.isHidden = true
        card.fit = { [unowned self] change in self.fit(change) }
        card.onReplyClick = { [unowned self] in self.skip() }
        card.onMenu = { [unowned self] action in self.menu(action) }
        card.onApprove = { [unowned self] choice in self.approve(ApprovalChoice(rawValue: choice) ?? .deny) }
        card.onNudge = { [unowned self] outcome in self.nudgeAnswered(outcome) }
        face.setTheme(hue: hueFunction(theme), bg: screenColours(theme), snap: true)
        face.onMouse = { [unowned self] kind in self.faceMouse(kind) }
        layoutWindow(keeping: nil)  // just the face; the card is hidden and takes no room

        roamTimer = commonTimer(RoboWindow.roamSlow) { [weak self] in self?.roam() }  // resting; see scheduleRoam
        ticker = commonTimer(0.1) { [weak self] in self?.tick() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() }
        if watchWake {
            wakeWatcher = WakeWatcher { [weak self] in DispatchQueue.main.async { self?.maybeDigest(); self?.nudgeWoke() } }
            wakeWatcher?.start()
        }
        if let watcher {
            watcher.pause(FileManager.default.fileExists(atPath: machine.watchPausedFile.path))
            watcher.start()
        }
        if let listener {
            let e = listener({ [bridge] in bridge.event(.listening(true)) }, { [bridge] in bridge.heard($0) },
                             { [bridge] in bridge.note($0) })
            ear = e.start() ? e : nil
            hotkey?.onDown = { [weak self] in self?.talkDown() }
            hotkey?.onUp = { [weak self] in self?.ear?.release() }
        }
        if !health.isEmpty {
            let make: PollerFactory = makePoller ?? { HealthPoller(url: $0, onState: $1) }
            poller = make(health) { [bridge] in bridge.link($0) }
            poller?.start()
        }
        DispatchQueue.main.async { [weak self] in
            self?.maybeDigest()
            self?.startNudges()
        }
    }

    deinit {
        for t in [ticker, roamTimer, revealer, shadeTimer] { t?.invalidate() }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func now() -> Double { machine.clock() }

    /// Put the window on screen (without making robo the active app).
    func show() { panel.orderFrontRegardless() }

    // MARK: - layout

    var faceSize: Vec { Vec(FaceView.size.width, FaceView.size.height) }
    var windowTopLeft: Vec { space.topLeft(of: panel.frame) }
    /// Where the middle of the face is, on the screens' y-down plane.
    var faceCentre: Vec { windowTopLeft + Vec(face.frame.midX, face.frame.midY) }

    /// Apply `change` (show or hide a part of the card) and resize, keeping the face where it is: the
    /// window grows upward and symmetrically around the face. Nested calls lay out once, at the end.
    func fit(_ change: () -> Void) {
        if fitDepth > 0 { change(); return }
        fitDepth += 1
        let faceAt = windowTopLeft + Vec(face.frame.minX, face.frame.minY)  // before `change`
        change()
        fitDepth -= 1
        layoutWindow(keeping: faceAt)
    }

    /// Size the window to its content (the face, and the card above it while it shows) and put it where
    /// `faceAt` says the face is; nil keeps the roamer's position.
    func layoutWindow(keeping faceAt: Vec?) {
        let m = RoboWindow.margin, g = RoboWindow.gap
        let shown = !card.isHidden
        let cardH = shown ? Double(card.fittingHeight.rounded(.up)) : 0
        let w = (shown ? Double(CardView.width) : faceSize.x) + 2 * m
        let size = Vec(w, shown ? cardH + g + faceSize.y + 2 * m : faceSize.y + 2 * m)
        let faceOffset = Vec(shown ? (w - faceSize.x) / 2 : m, shown ? m + cardH + g : m)
        roamer.resize(size)
        if let faceAt {
            roamer.pos = faceAt - faceOffset
            roamer.resize(size)  // and keep it on screen
        }
        card.frame = CGRect(x: m, y: m, width: Double(CardView.width), height: cardH)
        face.frame = CGRect(x: faceOffset.x, y: faceOffset.y, width: faceSize.x, height: faceSize.y)
        let pos = Vec(roamer.pos.x.rounded(), roamer.pos.y.rounded())
        let frame = space.frame(topLeft: pos, size: size)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    /// Move the window (not its size) to `pos` on the y-down plane.
    func move(to pos: Vec) {
        let origin = space.frame(topLeft: Vec(pos.x.rounded(), pos.y.rounded()), size: Vec(panel.frame.width, panel.frame.height)).origin
        if origin != panel.frame.origin { panel.setFrameOrigin(origin) }
    }

    // MARK: - roaming

    func roam() {
        // it walks to a corner and stays; the right-click menu opens the card too, but it must not leave
        // before the user can press Stay. A nudge is not a call either, but it freezes the pet like a press: the card is attached
        // to it, and buttons that drift at 40 px/s are hard to hit (seen live: 1200 px in a minute)
        let called = busy || (!card.isHidden && card.chips.isHidden && nudge.shown.isEmpty)
        let p = roamer.step(now: now(), asleep: mind.activity == .asleep, engaged: press != nil || !nudge.shown.isEmpty, called: called)
        let at = windowTopLeft
        if Double(p.x) != at.x.rounded() || Double(p.y) != at.y.rounded() { move(to: Vec(Double(p.x), Double(p.y))) }
        scheduleRoam()
    }

    /// 30 steps a second only while something moves: walking, hopping off a wall, or a sleeper or a call on its
    /// way to a corner. Resting, held (10 minutes after a drop) and asleep in its corner, nothing changes between
    /// two half seconds.
    func scheduleRoam() {
        let travelling = (roamer.mode == .sleep || roamer.mode == .come) && roamer.pos != roamer.goal
        let moving = roamer.mode == .drift || travelling || roamer.bouncing
        let wanted = moving ? RoboWindow.roamFast : RoboWindow.roamSlow
        guard wanted != roamInterval else { return }
        roamInterval = wanted
        roamTimer?.invalidate()
        roamTimer = commonTimer(wanted) { [weak self] in self?.roam() }
    }

    /// A monitor came, went or resized: keep robo on the screens that are left. The screens are read AFTER
    /// the event (a removed one is still listed while its notification runs).
    func screensChanged() { DispatchQueue.main.async { [weak self] in self?.refit() } }

    func refit() {
        let displays = machine.displays()
        guard let fresh = ScreenSpace(displays) else { return }  // none for a moment while a display sleeps: keep the last layout
        // AppKit's origin is the primary display's: where the window is now, in the new arrangement
        roamer.pos = fresh.topLeft(of: panel.frame)
        space = fresh
        roamer.setScreens(fresh.roamArea(displays))
        move(to: roamer.pos)
    }

    // MARK: - the face: click = listen, drag = move robo and leave it there

    func faceMouse(_ kind: FaceMouse) {
        let here = space.point(machine.pointer())
        switch kind {
        case .rightPress:
            showMenu()
        case .press:
            press = here
            dragged = false
            grabAt = here - windowTopLeft
        case .drag:
            guard let start = press else { return }
            let d = here - start
            if dragged || abs(d.x) + abs(d.y) > RoboWindow.drag {
                dragged = true
                // hold on every move: else the roam tick pulls the window back to where it was; the hold also keeps it
                // on the main display (a drag past its edge stops at the edge)
                roamer.hold(now: now(), pos: here - grabAt)
                move(to: roamer.pos)
            }
        case .release:
            guard press != nil else { return }
            if dragged {
                roamer.hold(now: now(), pos: windowTopLeft)
            } else {
                clicked()
            }
            press = nil
        }
    }

    func clicked() {
        if !busy && !card.isHidden && closeAt != 0 {
            closeBubble()
        } else if let ear, ear.running {  // a dead one must not leave robo "listening"
            ear.listenNow()
            onEvent(.listening(true))  // show it at once (and interrupt an answer)
        } else if busy {
            stop()
        } else {
            typeText()
        }
    }

    /// The push-to-talk key went down: robo listens until it comes up.
    func talkDown() {
        guard let ear, ear.running else { return }
        ear.hold()
        onEvent(.listening(true))  // show it at once (and interrupt an answer)
    }

    // MARK: - the right-click menu

    func showMenu() {
        let stamp = Themes.stamp(path: machine.themeFile)
        if stamp != themeStamp {  // theme.json was edited by hand: show it now
            themeStamp = stamp
            applyTheme(Themes.load(path: machine.themeFile))
        }
        let now = now()
        card.showMenu(stay: roamer.stays(now: now) ? "🧭 Wander" : "📌 Stay",
                      watch: watcher?.paused == true ? "▶ Watch" : "⏸ Watch",
                      nudges: nudge.state.enabled ? "🔔 Nudges" : "🔕 Nudges")
        open(closeAfter: 8)
    }

    func menu(_ action: MenuAction) {
        switch action {
        case .digest: ask(RoboWindow.digestPrompt)
        case .type: typeText()
        case .stay: toggleStay()
        case .watch: toggleWatch()
        case .nudges: toggleNudges()
        case .quit: quit()
        }
    }

    func toggleStay() {
        let now = now()
        let stay = roamer.stays(now: now)
        roamer.hold(now: now, pos: windowTopLeft, seconds: stay ? 0 : 1e9)
    }

    /// Pause or resume activity watching; the choice survives a restart.
    func toggleWatch() {
        guard let watcher else { return }
        let paused = !watcher.paused
        watcher.pause(paused)
        let file = machine.watchPausedFile
        if paused {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - themes

    func hueFunction(_ t: Theme) -> (String, String, Double) -> Double {
        { activity, emotion, base in Themes.hueFor(t, activity: activity, emotion: emotion, base: base) }
    }

    func screenColours(_ t: Theme) -> (RGBA, RGBA) { (Themes.rgba(t.faceBg.centre), Themes.rgba(t.faceBg.edge)) }

    /// Switch the look live (theme.json was edited), nothing restarts: face colours, card, typing speed, sizes.
    func applyTheme(_ t: Theme) {
        theme = t
        face.setTheme(hue: hueFunction(t), bg: screenColours(t))
        card.setTheme(t)  // restyles the header, quote, dots and caret too
        card.setHue(Themes.liveHue(t, faceNow: face.params.hue, activity: mind.activity.rawValue))
        var pace = tw.pace
        pace.cps = t.cps
        tw.setPace(pace)
        render()  // the reply in the new look
        resume()  // a faster speed may be done, a slower one starts again
        fit {}  // fonts and gaps changed every height
    }

    // MARK: - typing a question

    /// A small window of its own, on the face's display.
    func typeText() {
        typer?.close()
        let t = TypePanel { [weak self] in self?.ask($0) }
        t.onClose = { [weak self, weak t] in if self?.typer === t { self?.typerOpen = false } }
        let displays = machine.displays()
        if let d = space.display(at: faceCentre, in: displays) { t.place(on: d.visible) }
        typer = t
        typerOpen = true
        machine.showTyper(t)
    }

    // MARK: - escape and leaving

    /// The panel took the keyboard when a click selected reply text. Once the card is gone nothing on the pet
    /// can use it: resign key (ordering out and in again is how a window gives it up) and, if robo's app was
    /// activated meanwhile, hand the activation back to the app that had it.
    func releaseKeyboard() {
        guard panel.isKeyWindow else { return }
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        machine.focus.handBack(to: previousApp)
        previousApp = nil
    }

    func escape() {
        if busy {
            stop()
        } else if tw.pending {
            skip()  // first Esc shows the rest, the next one closes
        } else {
            closeBubble()
        }
    }

    /// Never leave a run (maybe acting on the laptop) going with nobody watching, and end the app when that
    /// is done (the menu's Quit).
    func quit() {
        shutdown { [self] in machine.terminate() }
    }

    /// What NSApplication asks its delegate on a logout or an Apple Event quit: the same cleanup, and the app
    /// ends when `reply` is called.
    func shouldTerminate(reply: @escaping () -> Void) -> NSApplication.TerminateReply {
        if shutdownDone { return .terminateNow }
        shutdown(reply)
        return .terminateLater
    }

    /// The pet goes first and the waits happen off the main thread: a run being created gets its id within
    /// moments (up to `idWait` s), then it is stopped, then the poller, the wake watcher, the microphone and the
    /// activity watcher (which may be mid-sample) are stopped. `done` runs on the main thread, once; calling
    /// this again while it works only adds a `done`.
    func shutdown(_ done: @escaping () -> Void) {
        if shutdownDone { return done() }
        shutdownWaiters.append(done)
        if shutdownStarted { return }
        shutdownStarted = true
        scout.running?.cancel()  // best effort: the scan only reads, so a run that outlives the app is harmless
        panel.orderOut(nil)
        typer?.close()
        for t in [ticker, roamTimer, revealer, shadeTimer] { t?.invalidate() }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        let wasBusy = lock.withLock { () -> Bool in
            cancel = busy
            return busy
        }
        DispatchQueue.global().async { [self] in
            let end = Date(timeIntervalSinceNow: idWait)
            var id: String?
            while wasBusy, Date() < end {
                id = lock.withLock { runID }
                if id != nil { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if let id { stopAndWait(id) }
            poller?.stop()
            wakeWatcher?.stop()
            ear?.stop(wait: 0.5)
            watcher?.stop()
            DispatchQueue.main.async { [self] in
                shutdownDone = true
                let waiting = shutdownWaiters
                shutdownWaiters = []
                waiting.forEach { $0() }
            }
        }
    }

    private func stopAndWait(_ id: String) {
        let done = DispatchSemaphore(value: 0)
        Task { [hermes] in
            try? await hermes.stop(id)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
    }
}

// The window lives on the main thread; the worker reaches it only through `lock` and the bridge.
extension RoboWindow: @unchecked Sendable {}
