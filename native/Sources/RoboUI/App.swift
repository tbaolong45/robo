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
        if busy {
            pending = text
            stop()
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
        Task.detached { [self] in
            await work(text, session: session, waitNetwork: waitNetwork, scan: { Self.made(output: output, vault: vault, since: since) })
        }
    }

    /// The worker (any thread): everything it learns goes to the main thread through the bridge.
    /// `scan` reads what the request made, here and not at the end of the run on the main thread: the folders\n    /// can hold tens of thousands of files.
    func work(_ text: String, session: String, waitNetwork: Bool, scan: () -> Made) async {
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
            for try await ev in hermes.ask(text, sessionId: session, started: { [weak self] id in self?.started(id) }) {
                if case .runEnded("completed", _, _) = ev {
                    let found = scan()
                    lock.withLock { scanned = found }
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

    func approve(_ choice: ApprovalChoice) {
        card.setApproval(nil)
        if let id = lock.withLock({ runID }) { background { [hermes] in try await hermes.approve(id, choice) } }
    }

    /// The run's own stream reports what happened, so a failed call is ignored.
    func background(_ call: @escaping () async throws -> Void) {
        Task { try? await call() }
    }

    // MARK: - voice

    func onHeard(_ text: String) {
        onEvent(.listening(false))
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty {
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
            noted = false
            setHeard("")
            clearReply()
            open()
        case .userSent:
            open()
        case .delta(let t):
            reply += t
            feed(reply)
        case .approvalNeeded(_, desktop: true):
            // The user lets robo drive the desktop freely ("all but irreversible"); "session" covers that
            // kind of desktop step for the rest of this request only.
            if let id = lock.withLock({ runID }) { background { [hermes] in try await hermes.approve(id, .session) } }
            refresh()
            return
        case .approvalNeeded(let d, _):
            let scalars = d.unicodeScalars
            let shown = scalars.count <= RoboWindow.approvalMax ? d
                : String(String.UnicodeScalarView(scalars.prefix(RoboWindow.approvalMax - 1))) + "…"
            card.setApproval(shown)  // room for the buttons: the window grows
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
        card.setApproval(nil)
        var text = status == "completed" ? (output.isEmpty ? reply : output) : (error.isEmpty ? "Run \(status)." : error)
        if listening {  // interrupted by the user speaking: keep listening
            mind = mind.react(.listening(true), now: now())
        }
        if let day = digestDay, status == "completed" { try? digest.mark(day) }
        if status == "completed" { answeredAt = now() }
        var lines: [String] = []
        if status == "completed" && !listening {
            let (notes, files) = (made?.notes ?? [], made?.files ?? [])
            for n in notes { machine.openNote(n, !autoDigest) }  // the automatic digest opens behind what you are doing
            for f in files { machine.openFile(f) }
            if !notes.isEmpty { lines.append("📓 In Obsidian: " + notes.map { $0.deletingPathExtension().lastPathComponent }.joined(separator: ", ")) }
            if !files.isEmpty { lines.append("📂 Opened " + files.map(\.lastPathComponent).joined(separator: ", ")) }
        }
        if !listening && pending.isEmpty {
            card.setFooter(lines.joined(separator: "\n"))  // shown when the typing is done
            feed(text, end: true)
        }
        if let ear, status == "completed", pending.isEmpty { ear.followUp(seconds: RoboWindow.followUpS) }  // a reply needs no "robo"
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
        card.setLights(link: link, mic: CardView.micState(listenerReady: ear?.ready, activity: m.activity, noted: noted))
        card.setPhase(now)
        caret(now)
        let listeningNow = m.activity == .listening
        let thinking = busy && reply.isEmpty && !listeningNow
        let label = listeningNow ? "listening" : thinking ? m.label : ""  // e.g. "searching the web…" beside the dots
        card.setStatusRow(typing: thinking, label: label)
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
        card.clearReply()
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

    /// Show the card; it closes `closeAfter` s after the reply is typed (0: stays).
    func open(closeAfter after: Double = 0) {
        closeAfter = after
        let armed = after != 0 && !tw.pending  // while it types, finishedTyping arms the timer
        closeAt = armed ? now() + after : 0
        if card.isHidden {
            fit { card.isHidden = false }
            fadeIn()
        }
    }

    /// The card appears with a short fade (closing stays instant: the window shrinks around the face at once).
    /// The model value is 1 straight away, only what is on screen eases in; Reduce Motion skips it.
    private func fadeIn() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        card.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            card.animator().alphaValue = 1
        }
    }

    func closeBubble() {
        closeAt = 0
        fit {
            card.hideMenu()
            card.isHidden = true
        }
        releaseKeyboard()
    }

    // MARK: - what robo made opens by itself

    /// What a finished request made: Obsidian notes and files in the output folder.
    struct Made {
        var notes: [URL] = [], files: [URL] = []
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
