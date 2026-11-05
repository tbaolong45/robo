// The conversation: asking the agent, what its events do to the face and the card, the reply
// typed letter by letter, and the card's life (open, close in a while).
import AppKit
import RoboCore
import RoboVoice

extension RoboWindow {
    // MARK: - talking to the agent

    /// Start one run; while another is in flight, stop it and ask this one after it.
    func ask(_ text: String) {
        if chatOpen && Intent.closesChat(text) {  // "close the chat" closes the chat window; it is not a request for the agent
            closeChat()
            return
        }
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
        }
        reply = ""
        runStart = now()
        // One agent session per day and persona version (Setup persona stamp).
        sessionID = ["robo", day.iso, persona].filter { !$0.isEmpty }.joined(separator: "-")
        if machine.chatOn {
            // Your turn and Robo's answer go to the chat window, which keeps the conversation; the pet's card only listened.
            chatBegin(you: text)
            clearReply()
        } else {
            let shown = !tw.text.isEmpty && !card.isHidden  // an answer is still up, or just
            let follow = shown || now() - answeredAt < RoboWindow.followUpS  // was: this follows it up
            setHeard(text, followUp: follow)
            clearReply()
        }
        onEvent(.userSent(text))
        let session = sessionID
        Task.detached { [self] in await work(text, session: session) }
    }

    /// The worker (any thread): everything it learns goes to the main thread through the bridge.
    func work(_ text: String, session: String) async {
        let emit = bridge.event
        if lock.withLock({ cancel }) {
            emit(.runEnded(status: "cancelled"))
            return
        }
        do {
            for try await ev in agent.ask(text, sessionId: session, started: { [weak self] id in self?.started(id) }) { emit(ev) }
        } catch let e as BrainError {
            poller?.poke()  // is the agent down? the light says so within a second
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
        if stopNow { background { [agent] in try await agent.stop(id) } }
    }

    func stop() {
        var run: String?
        let running = lock.withLock { () -> Bool in
            guard busy else { return false }
            cancel = true
            run = runID
            return true
        }
        if running, let run { background { [agent] in try await agent.stop(run) } }
    }

    /// The run's own stream reports what happened, so a failed call is ignored.
    func background(_ call: @escaping () async throws -> Void) {
        Task { try? await call() }
    }

    // MARK: - voice

    func onHeard(_ text: String, handsFree: Bool) {
        onEvent(.listening(false))  // changes nothing unless robo was listening
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty && handsFree {  // said in the follow-up window without the key: robo has not woken for it yet
            onEvent(.listening(true))  // the wake the listener left to us (it stops a run and clears the last reply)
            onEvent(.listening(false))
        }
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
    /// of the reply: the agent goes on and `runEnded` finishes it.
    func say(_ text: String) {
        if chatOpen {  // a notice is a line of the conversation; the answer being typed (if any) is not touched
            retireListeningCard()
            transcript.note(text)
            chat?.chat.set(turns: transcript.turns)
            return
        }
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
            chatInterrupted(stopped: busy, footer: busy ? [] : chatFooter)  // an answer being written in the chat is kept as far as it got
            setHeard("")
            clearReply()
            open()  // the pet's card listens; the chat opens when there is something to ask
        case .userSent:
            if !machine.chatOn { open() }
        case .delta(let t):
            reply += t
            feed(reply)
        case .runEnded(let status, let output, let error):
            ended(status: status, output: output, error: error)
        default:
            break
        }
        listening = mind.activity == .listening
        if called && roamer.mode != .come { roam() }  // a call starts now: the resting tick can be half a second away
        refresh()
    }

    private func ended(status: String, output: String, error: String) {
        lock.withLock {
            busy = false
            runID = nil
        }
        var text = status == "completed" ? (output.isEmpty ? reply : output) : (error.isEmpty ? "Run \(status)." : error)
        if listening {  // interrupted by the user speaking: keep listening
            mind = mind.react(.listening(true), now: now())
        }
        if status == "completed" { answeredAt = now() }
        followDue = status == "completed" && pending.isEmpty && !listening  // a reply needs no "robo", once it is typed (finishedTyping)
        let toChat = machine.chatOn && chatOpen  // the answer is written in the chat window (else on the pet's card, as before)
        let cutShort = toChat && status != "completed" && !reply.isEmpty  // what arrived stays, marked as stopped
        if cutShort { text = reply }
        let footer = cutShort ? ["stopped"] : []
        if !listening && pending.isEmpty {
            if machine.chatOn { (chatFooter, chatFailed) = (footer, status != "completed" && !cutShort) }  // sealed when the typing is done
            feed(text, end: true)
        } else if toChat {
            chatInterrupted(stopped: status != "completed", footer: footer)  // you spoke or asked again: nothing more is typed
        }
        if !toChat { open(closeAfter: listening ? 0 : RoboWindow.closeAfter) }
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
        if !card.isHidden && now >= sampleAt { look() }  // nothing runs while the card is away
        if chatOpen && now >= chatSampleAt { chatLook() }  // one look at a time (`sampling`): the other tries again at the next tick
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
        card.setLights(link: link, mic: CardView.micState(listenerReady: ear?.ready, activity: m.activity, noted: noted,
                                                          following: now < followUntil && !busy))
        card.setPhase(now)
        caret(now)
        let listeningNow = m.activity == .listening
        let thinking = busy && reply.isEmpty && !listeningNow
        let label = listeningNow ? "listening" : thinking ? workingLabel(now) : ""  // beside the dots
        card.setStatusRow(typing: thinking, label: label)
        refreshChat(listening: listeningNow, thinking: thinking, label: label)
        // Listening, or typing in the chat: the rest of the screen is blurred a little, the pet and the chat stay sharp.
        let typingInChat = chatOpen && chat.map(machine.chatTyping) == true
        let blur = machine.chatOn && (typingInChat || listeningNow) && !shutdownStarted
        if blur != blurShown {
            blurShown = blur
            machine.blurBackground(blur, machine.displays().first?.frame ?? .zero)
        }
    }

    /// The line beside the dots while the agent works: "on it…", and from 40 s on how long it has gone, every 20 s
    /// ("still working · 60 s").
    func workingLabel(_ now: Double) -> String {
        let seconds = Int(max(0, now - runStart))
        return seconds >= 40 ? "still working · \(seconds / 20 * 20) s" : "on it…"
    }

    /// Shown while the reply types and for `caretS` after: solid just after a letter, else blinking
    /// (waiting for the agent, or in a pause).
    func caret(_ now: Double) {
        let show = !tw.text.isEmpty && !tw.instant && (!tw.done || now < typedAt + RoboWindow.caretS)
        let blink = Int(now * 1000 / Double(theme.caretMs)) % 2 == 0
        card.setCaret(show: show, on: show && (now - lastChar < RoboWindow.solidS || blink))
    }

    // MARK: - the reply: typed letter by letter

    /// What you said, above the answer (hidden when there is none).
    func setHeard(_ text: String, followUp: Bool = false) {
        card.setHeard(text, followUp: followUp)
    }

    /// A new exchange: nothing of the last reply stays (text, typing, caret, timer).
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

    /// Hand the typewriter the reply so far (`end`: that is all of it, as the agent finished).
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

    /// Nothing is due any more: stop the steps; when the agent is done too, the reply is typed.
    func settle() {
        if !tw.pending {
            revealer?.invalidate()
            revealer = nil
            if tw.done && !typed { finishedTyping() }
        }
    }

    /// The reply is all on screen: let the card close in a while.
    func finishedTyping() {
        typed = true
        typedAt = now()
        let toChat = machine.chatOn && chatOpen
        chatSealed()  // the answer in the conversation is final now, with its footer
        announceReply(inChat: toChat)
        if closeAfter != 0 && !busy && !toChat { closeAt = typedAt + closeAfter }  // the chat is not closed by a timer
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
        if machine.chatOn && chatOpen {
            chat?.chat.setLive(markdown: markdown, hidden: hidden)
        } else {
            card.setReply(markdown: markdown, hiddenTail: hidden)
        }
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
            if !askedScreen {
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
        if !chatOpen { endFollowUp() }  // the chat's answer may still be waiting for your reply: a card closing does not end that
        fit {
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
}
