// The conversation half of app.py: asking Hermes, what its events do to the face and the card, the reply
// typed letter by letter, the card's life (open, close in a while), and what robo made opening by itself.
// Plus `RoboApp.run()`, the app itself.
import AppKit
import RoboCore
import RoboSystem
import RoboVoice

extension RoboWindow {
    // MARK: - talking to Hermes

    /// Start one run; while another is in flight, stop it and ask this one after it.
    func ask(_ text: String, waitNetwork: Bool = false) {
        dismissNudge()  // a request of any kind takes the card: the nudge is closed unanswered
        if busy {
            pending = text
            stop()
            return
        }
        let cap = machine.dailyTokens
        if cap > 0 && Usage.todayTokens(file: machine.usageFile, now: machine.wall()) >= cap {  // no run starts: it would only cost more
            say("Today's token budget (\(cap)) is used up. Set ROBO_DAILY_TOKENS higher or wait for tomorrow.")
            return
        }
        let day = today()
        lock.withLock {
            busy = true
            runID = nil
            cancel = false
            scanned = nil
        }
        reply = ""
        runStart = now()
        toolLabel = ""
        // One Hermes session per day and persona version (Setup persona stamp).
        sessionID = ["robo", day.iso, persona].filter { !$0.isEmpty }.joined(separator: "-")
        digestDay = text == RoboWindow.digestPrompt ? day : nil
        autoDigest = waitNetwork && digestDay != nil
        startedAt = machine.wall()  // files robo makes from now on are opened when it's done
        let shown = !tw.text.isEmpty && !card.isHidden  // an answer is still up, or just
        let follow = shown || now() - answeredAt < RoboWindow.followUpS  // was: this follows it up
        setHeard(digestDay != nil ? "" : text, followUp: follow)
        clearReply()
        onEvent(.userSent(text))
        let (session, since, output, vault) = (sessionID, startedAt, machine.outputDir, machine.vaultDir)
        let (receipts, usageFile, clock, wall, began) = (machine.receiptsFile, machine.usageFile, machine.clock, machine.wall, runStart)
        Task.detached { [self] in
            await work(text, session: session, waitNetwork: waitNetwork, finish: { status, reply, usage, steps in
                var found = status == "completed" ? Self.made(output: output, vault: vault, since: since) : Made()
                found.receipts = Receipt.lines(reply: reply, evidence: ReceiptLog.read(receipts, since: since))
                Usage.append(Usage.line(usage, status: status, seconds: clock() - began, steps: steps, wall: wall()), to: usageFile)
                return found
            })
        }
    }

    /// The worker (any thread): everything it learns goes to the main thread through the bridge.
    /// `finish` (the run ended `status`, with this `reply`, `usage` and number of tool `steps`) reads what the request made and
    /// what the guard recorded, and logs the run: here and not at the end of the run on the main thread, as the folders can
    /// hold tens of thousands of files.
    func work(_ text: String, session: String, waitNetwork: Bool,
              finish: (_ status: String, _ reply: String, _ usage: UsageRecord?, _ steps: Int) -> Made) async {
        let emit = bridge.event
        if waitNetwork {
            let online = await withCheckedContinuation { c in
                DispatchQueue.global().async {
                    c.resume(returning: waitForNetwork { self.lock.withLock { self.cancel } || self.network() })
                }
            }
            if !online {
                emit(.runEnded(status: "failed", error: "I can't reach the internet yet."))
                return
            }
        }
        if lock.withLock({ cancel }) {
            emit(.runEnded(status: "cancelled"))
            return
        }
        do {
            var streamed = "", steps = 0
            var usage: UsageRecord?
            for try await ev in hermes.ask(text, sessionId: session, started: { [weak self] id in self?.started(id) }) {
                switch ev {
                case .delta(let t): streamed += t
                case .toolStarted: steps += 1
                case .usage(let u): usage = u
                case .runEnded(let status, let output, _):
                    let found = finish(status, output.isEmpty ? streamed : output, usage, steps)
                    lock.withLock { scanned = found }
                default: break
                }
                emit(ev)
            }
        } catch let e as BrainError {
            poller?.poke()  // is the gateway down? the light says so within a second
            emit(.runEnded(status: "failed", error: e.message))
        } catch {  // never leave the window stuck "busy"
            emit(.runEnded(status: "failed", error: "Something went wrong: \(error)"))
        }
    }

    /// Worker thread: the run exists now; stop it at once if a stop came first.
    func started(_ id: String) {
        let stopNow = lock.withLock { () -> Bool in
            runID = id
            return cancel
        }
        if stopNow { background { [hermes] in try await hermes.stop(id) } }
    }

    func stop() {
        var run: String?
        let running = lock.withLock { () -> Bool in
            guard busy else { return false }
            cancel = true
            run = runID
            return true
        }
        if running, let run { background { [hermes] in try await hermes.stop(run) } }
    }

    /// A click on the card answers the ask it shows (the oldest), then the next one shows.
    func approve(_ choice: ApprovalChoice) {
        if !approvals.isEmpty { answer(choice, approvals.removeFirst().id) }
        showApproval()
    }

    /// Tell Hermes what to do about one ask, by its id: without one it answers the oldest pending ask, which may be another.
    func answer(_ choice: ApprovalChoice, _ id: String) {
        if let run = lock.withLock({ runID }) { background { [hermes] in try await hermes.approve(run, choice, requestId: id) } }
    }

    /// The card shows the oldest ask and how many wait behind it; with none it hides.
    func showApproval() {
        card.setApproval(approvals.first?.text, more: max(0, approvals.count - 1))
    }

    /// The run's own stream reports what happened, so a failed call is ignored.
    func background(_ call: @escaping () async throws -> Void) {
        Task { try? await call() }
    }

    // MARK: - voice

    func onHeard(_ text: String) {
        onEvent(.listening(false))
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty && ear?.handsFree == true && Intent.changesThings(said) {
            // said in the follow-up window, without the key (the TV or the room may have said it): never act on it
            say("That would change something, so hold Ctrl+Q and say it again.")
        } else if !said.isEmpty {
            ask(said)
        } else if !busy {
            say("Sorry, I didn't catch that.")
        }
    }

    func onNote(_ text: String) {
        noted = true  // the MIC light shows it until robo listens again
        onEvent(.listening(false))
        say(text)
    }

    func onLink(_ state: HealthState) {
        link = LedState(rawValue: state.rawValue) ?? .unknown
        refresh()
    }

    /// Show a short local message (no model involved), typed like an answer. During a run it is not the end
    /// of the reply: Hermes goes on and `runEnded` finishes it.
    func say(_ text: String) {
        dismissNudge()
        setHeard("")
        clearReply()
        feed(text, end: !busy)
        open(closeAfter: 8)
    }

    // MARK: - events

    func onEvent(_ ev: Event) {
        mind = mind.react(ev, now: now())
        switch ev {
        case .listening(true):
            stop()  // speaking over robo interrupts its answer
            dismissNudge()
            noted = false
            setHeard("")
            clearReply()
            open()
        case .userSent:
            open()
        case .delta(let t):
            reply += t
            feed(reply)
        case .toolStarted(let tool):
            toolLabel = Mind.toolLabel(tool)
        case .approvalNeeded(let d, let desktop, let id):
            if autoDigest || desktop {
                // The automatic digest only reads and nobody is looking: every ask is denied at once, none waits on a
                // card (a digest from the menu is attended and asks). Otherwise this is Hermes' own approval of a desktop
                // step; the user lets robo drive the desktop freely ("all but irreversible"), and "session" covers that
                // kind of step for the rest of this request only. robo-guard's asks (irreversible steps, Outlook and Teams
                // steps) are not `desktop`: they show the card.
                answer(autoDigest ? .deny : .session, id)
                refresh()
                return
            }
            let scalars = d.unicodeScalars
            let shown = scalars.count <= RoboWindow.approvalMax ? d
                : String(String.UnicodeScalarView(scalars.prefix(RoboWindow.approvalMax - 1))) + "…"
            approvals.append((id, shown))  // parallel tool calls ask together: in order, the oldest first
            showApproval()  // room for the buttons: the window grows
            open()
        case .runEnded(let status, let output, let error):
            ended(status: status, output: output, error: error)
        default:
            break
        }
        listening = mind.activity == .listening
        refresh()
    }

    private func ended(status: String, output: String, error: String) {
        let made = lock.withLock { () -> Made? in
            busy = false
            runID = nil
            defer { scanned = nil }
            return scanned
        }
        approvals.removeAll()  // a run that ended has nothing left to ask
        showApproval()
        toolLabel = ""
        var text = status == "completed" ? (output.isEmpty ? reply : output) : (error.isEmpty ? "Run \(status)." : error)
        if listening {  // interrupted by the user speaking: keep listening
            mind = mind.react(.listening(true), now: now())
        }
        if let day = digestDay, status == "completed" { try? digest.mark(day) }
        if status == "completed" { answeredAt = now() }
        followDue = status == "completed" && pending.isEmpty && !listening  // a reply needs no "robo", once it is typed (finishedTyping)
        var lines: [String] = []
        if status == "completed" && !listening {
            let (notes, files) = (made?.notes ?? [], made?.files ?? [])
            for n in notes { machine.openNote(n, !autoDigest) }  // the automatic digest opens behind what you are doing
            for f in files { machine.openFile(f) }
            if !notes.isEmpty { lines.append("📓 In Obsidian: " + notes.map { $0.deletingPathExtension().lastPathComponent }.joined(separator: ", ")) }
            if !files.isEmpty { lines.append("📂 Opened " + files.map(\.lastPathComponent).joined(separator: ", ")) }
        }
        if !listening { lines += made?.receipts ?? [] }  // what the guard recorded, also under a failed or stopped run: a send may have happened
        if !listening && pending.isEmpty {
            card.setFooter(lines.joined(separator: "\n"))  // shown when the typing is done
            feed(text, end: true)
        }
        digestDay = nil
        open(closeAfter: listening ? 0 : RoboWindow.closeAfter)
        if !pending.isEmpty {
            text = pending
            pending = ""
            DispatchQueue.main.async { [weak self] in self?.ask(text) }
        }
    }

    // MARK: - the 100 ms tick and the pet's life

    func tick() {
        let now = now()
        mind = mind.tick(now: now)
        if closeAt != 0 && now >= closeAt && !busy {
            if card.isUnderMouse {
                closeAt = now + 5
            } else {
                closeBubble()
            }
        }
        alive(now)
        if machine.wall() >= nudge.checkAt { nudgeTick() }  // wall time: the Mac's sleep does not stop a deadline
        if !card.isHidden && now >= sampleAt { look() }  // nothing runs while the card is away
        refresh()
    }

    /// Pet behaviour: the eyes follow the pointer while it moves (else lead the walk), and an idle robo now
    /// and then shows a mood.
    func alive(_ now: Double) {
        let here = space.point(machine.pointer())
        if here != cursor {
            cursor = here
            cursorMoved = now
        }
        face.setLook(lookAt(centre: faceCentre, cursor: here, stillFor: now - cursorMoved, heading: roamer.heading))
        if now >= fidgetAt {
            fidgetAt = now + Double.random(in: RoboWindow.fidgetEvery)
            if mind.activity == .idle && !busy && card.isHidden {
                mind = mind.react(.feeling(RoboWindow.fidgets.randomElement()!), now: now)
            }
        }
    }

    /// Push what the mind says to the face and the card.
    func refresh() {
        let m = mind, now = now()
        // The mouth follows the letters appearing, not the stream: while some are still due the face keeps
        // talking (the mind goes idle at runEnded), but an error keeps its sad face.
        let typing = tw.pending
        let activity: Activity = typing && (m.activity == .idle || m.activity == .talking) ? .talking : m.activity
        face.setState(activity: activity, emotion: m.emotion, talking: typing ? tw.revealing : m.talking)
        card.setHue(Themes.liveHue(theme, faceNow: face.params.hue, activity: m.activity.rawValue))
        card.setLights(link: link, mic: CardView.micState(listenerReady: ear?.ready, activity: m.activity, noted: noted,
                                                          following: now < followUntil && !busy))
        card.setPhase(now)
        caret(now)
        let listeningNow = m.activity == .listening
        let thinking = busy && reply.isEmpty && !listeningNow
        let label = listeningNow ? "listening" : thinking ? workingLabel(m, now) : ""  // e.g. "searching the web…" beside the dots
        card.setStatusRow(typing: thinking, label: label)
    }

    /// The line beside the dots while Hermes works: what the last tool does (it stays while the model thinks between tools),
    /// "on it…" before the first one, and from 40 s on how long it has gone, every 20 s ("still working · 60 s"). Nothing
    /// while the card asks the user something: the wait is theirs.
    func workingLabel(_ m: Mind, _ now: Double) -> String {
        if m.activity == .waiting { return "" }
        let seconds = Int(max(0, now - runStart))
        if seconds >= 40 { return "still working · \(seconds / 20 * 20) s" }
        return m.label.isEmpty ? (toolLabel.isEmpty ? "on it…" : toolLabel) : m.label
    }

    /// Shown while the reply types and for `caretS` after: solid just after a letter, else blinking
    /// (waiting for Hermes, or in a pause).
    func caret(_ now: Double) {
        let show = !tw.text.isEmpty && !tw.instant && (!tw.done || now < typedAt + RoboWindow.caretS)
        let blink = Int(now * 1000 / Double(theme.caretMs)) % 2 == 0
        card.setCaret(show: show, on: show && (now - lastChar < RoboWindow.solidS || blink))
    }

    // MARK: - the reply: typed letter by letter

    /// What you said, above the answer (hidden when there is none, as for the digest).
    func setHeard(_ text: String, followUp: Bool = false) {
        card.setHeard(text, followUp: followUp)
    }

    /// A new exchange: nothing of the last reply stays (text, typing, caret, footer, timer).
    func clearReply() {
        tw.reset()
        revealer?.invalidate()
        revealer = nil
        typed = false
        mouth = false
        closeAt = 0
        endFollowUp()
        card.clearReply()
    }

    /// A new exchange, a local message or a closed card ends the key-less follow-up window and its MIC light.
    func endFollowUp() {
        followDue = false
        followUntil = 0
        ear?.followUp(seconds: 0)
    }

    /// Hand the typewriter the reply so far (`end`: that is all of it, as Hermes finished).
    func feed(_ text: String, end: Bool = false) {
        if end { tw.end(text) } else { tw.feed(text) }
        resume()
    }

    /// Start typing if letters are due; else everything is there: show it and finish.
    func resume() {
        if tw.pending {
            closeAt = 0  // a reply is never closed under the reader
            if revealer == nil {
                lastTick = now() - RoboWindow.typeS
                revealer = commonTimer(RoboWindow.typeS) { [weak self] in self?.reveal() }
                reveal()  // the first letters now, not a step later
            }
        } else {
            render()
            settle()
        }
    }

    /// One typing step: the letters due, the mouth, and the end.
    func reveal() {
        let now = now()
        let dt = min(now - lastTick, 0.1)
        lastTick = now
        if tw.advance(dt) {
            lastChar = now
            render()
        }
        if tw.revealing != mouth {
            mouth = tw.revealing
            refresh()
        }
        settle()
    }

    /// Nothing is due any more: stop the steps; when Hermes is done too, the reply is typed.
    func settle() {
        if !tw.pending {
            revealer?.invalidate()
            revealer = nil
            if tw.done && !typed { finishedTyping() }
        }
    }

    /// The reply is all on screen: show the footer and let the card close in a while.
    func finishedTyping() {
        typed = true
        typedAt = now()
        card.showFooter()
        if closeAfter != 0 && !busy { closeAt = typedAt + closeAfter }
        if followDue && !busy {  // counted from the last letter: typing and reading must not eat the window
            followDue = false
            if let ear {
                followUntil = typedAt + RoboWindow.followUpS
                ear.followUp(seconds: RoboWindow.followUpS)
            }
        }
        refresh()
    }

    /// Put the typewriter's view into the card: the Markdown of the prefix, its last word laid out but
    /// invisible (so a word that will not fit the line wraps before it appears).
    func render() {
        let (markdown, hidden) = tw.view()
        card.setReply(markdown: markdown, hiddenTail: hidden)
    }

    /// Show the whole reply now, and whatever still arrives (click on the reply, Esc).
    func skip() {
        if !tw.text.isEmpty && !tw.done && !tw.skipped {
            tw.skip()
            resume()
        }
    }

    // MARK: - the card's life

    /// Show the card; it closes `closeAfter` s after the reply is typed (0: stays). `askScreen` false: a card nobody asked for (a
    /// nudge) never raises the system's Screen Recording dialog; the next card the user asks for does.
    func open(closeAfter after: Double = 0, askScreen: Bool = true) {
        closeAfter = after
        let armed = after != 0 && !tw.pending  // while it types, finishedTyping arms the timer
        closeAt = armed ? now() + after : 0
        if card.isHidden {
            fit { card.isHidden = false }
            fadeIn()
            if askScreen && !askedScreen {
                askedScreen = true
                machine.askScreenAccess()  // the system's dialog, once per launch; the card and its typing do not wait for it
            }
            look()  // the card's first look now, not a tick later
        }
    }

    /// The card appears with a short fade (closing stays instant: the window shrinks around the face at once).
    /// The model value is 1 straight away, only what is on screen eases in; Reduce Motion skips it.
    private func fadeIn() {
        guard !machine.reduceMotion() else { return }
        card.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            card.animator().alphaValue = 1
        }
    }

    func closeBubble() {
        closeAt = 0
        stopShading()
        endFollowUp()
        fit {
            dismissNudge()  // a nudge that is still up when the card goes was not answered
            card.hideMenu()
            card.isHidden = true
        }
        releaseKeyboard()
    }

    // MARK: - the backdrop: the card turns light over a dark screen and dark over a light one

    static let lookS = 0.25  // s between looks at what is behind the card while it shows (about 4 Hz)

    /// Where the glass is on the screens (AppKit coordinates): what it blurs is what is measured, and the card moves with the pet.
    var glassRect: CGRect { panel.convertToScreen(card.glass.convert(card.glass.bounds, to: nil)) }

    /// A look at the backdrop, one at a time; what it reads decides the shade. The card must be showing.
    func look() {
        guard !sampling else { return }
        sampling = true
        sampleAt = now() + RoboWindow.lookS
        machine.backdropLuma(glassRect) { [weak self] luma in
            guard let self else { return }
            sampling = false
            guard !card.isHidden, !shutdownStarted else { return }  // the card went away while it looked
            shade.see(luma: luma)
            applyShade()
        }
    }

    /// Show the shade: the glass and the ink at its level (a light card in light mode and a dark one in dark mode while the
    /// backdrop is not known: the ink is always explicit, so it can never be black on a glass that came out dark), easing at
    /// 30 Hz while it moves. Reduce Motion goes straight there.
    func applyShade() {
        guard shade.known else {
            stopShading()
            let level = machine.systemDark() ? 0.0 : 1.0
            card.setShade(level: level, ink: level)
            return
        }
        if machine.reduceMotion() { shade.snap() }
        card.setShade(level: shade.level, ink: shade.ink)
        if shade.moving && shadeTimer == nil {
            lastShade = now()
            shadeTimer = commonTimer(RoboWindow.typeS) { [weak self] in self?.ease() }
        }
    }

    /// One step of the ease; the timer is gone once the shade has arrived.
    func ease() {
        let t = now()
        let moving = shade.step(dt: min(t - lastShade, 0.1))
        lastShade = t
        card.setShade(level: shade.level, ink: shade.ink)
        if !moving { stopShading() }
    }

    func stopShading() {
        shadeTimer?.invalidate()
        shadeTimer = nil
    }

    // MARK: - what robo made opens by itself

    /// What a finished request made (Obsidian notes, files in the output folder) and what the guard recorded of it (footer lines).
    struct Made {
        var notes: [URL] = [], files: [URL] = []
        var receipts: [String] = []
    }

    private static let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]

    /// When `url` was written, if it is a regular file (through a link, as Python's `is_file` sees it) written
    /// since `started`.
    private static func written(_ url: URL, since started: Double) -> Date? {
        var values = try? url.resourceValues(forKeys: keys)
        if values?.isSymbolicLink == true { values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: keys) }
        guard let values, values.isRegularFile == true, let t = values.contentModificationDate,
              t.timeIntervalSince1970 >= started else { return nil }
        return t
    }

    /// The newest (at most `openMax`) of `found` written since `started`, newest first: one pass, nothing sorted.
    static func newest(_ found: some Sequence<URL>, since started: Double) -> [URL] {
        var top: [(url: URL, date: Date)] = []
        for url in found {
            guard let date = written(url, since: started) else { continue }
            let at = top.firstIndex { $0.date < date } ?? top.count  // after equals: the first found stays first
            if at < openMax { top.insert((url, date), at: at) }
            if top.count > openMax { top.removeLast() }
        }
        return top.map(\.url)
    }

    /// Everything under `dir` (a link to a folder too), with what `written` reads prefetched.
    private static func files(under dir: URL) -> some Sequence<URL> {
        let walk = FileManager.default.enumerator(at: dir.resolvingSymlinksInPath(), includingPropertiesForKeys: Array(keys))
        return (walk?.lazy.compactMap { $0 as? URL }).map { AnySequence($0) } ?? AnySequence([])
    }

    /// What was written under the output folder and the vault's Drafts, Plans and Notes since `started`: up to
    /// `openMax` notes first, then pages for what is left of the limit. Reads folders: not for the main thread.
    static func made(output: URL, vault: URL, since started: Double) -> Made {
        let notes = Vault.folders.flatMap { folder in
            newest(files(under: vault.appendingPathComponent(folder)).filter { $0.pathExtension == "md" }, since: started)
        }
        let top = newest(notes, since: started)
        return Made(notes: top, files: Array(newest(files(under: output), since: started).prefix(max(0, openMax - top.count))))
    }

    // MARK: - the digest

    func maybeDigest() {
        if digest.due(today()) && !busy { ask(RoboWindow.digestPrompt, waitNetwork: true) }
    }
}
