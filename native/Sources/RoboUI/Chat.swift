// The chat window's side of the pet's window: when it opens, what goes into it, how it closes, and what its glass does about the
// backdrop. The conversation is `transcript` (in memory, one per Hermes session); the window shows it (ChatPanel.swift, Bubbles.swift).
//   - It opens when you ask for something (typed, spoken, the digest) and stays until you tell Robo to close it ("close the chat",
//     spoken or typed; `Intent.closesChat`): no timer, no click on the pet closes it; Esc closes it only while its text box has the keyboard.
//   - Your turn and Robo's answer go into it; the answer is typed letter by letter into its bubble by the same typewriter as the pet's
//     card. A local notice ("Sorry, I didn't catch that.") is a line of it. The pet's card keeps what is quick and about the pet: the
//     menu, "listening", Allow/Deny and the nudges.
//   - If you close it while an answer is on its way, the answer shows on the pet's card instead: nothing is lost.
//   - It looks at what is behind it a few times a second (`Backdrop`, one look at a time with the card's) and turns light over a dark
//     screen and dark over a light one: the glass crossfades and the PANEL's appearance flips, so the text, which uses the system's
//     own colours, follows without being rebuilt.
import AppKit
import RoboCore

extension RoboWindow {
    static let chatLookS = 0.5  // s between looks at what is behind the chat while it shows

    /// The usable area of the main display, in AppKit coordinates: the middle of it is where the chat opens.
    private var mainVisible: CGRect { machine.displays().first?.visible ?? CGRect(x: 0, y: 0, width: 1440, height: 875) }

    // MARK: open and close

    private func makeChat() -> ChatPanel {
        let p = ChatPanel(theme: theme, reduceMotion: machine.reduceMotion)
        p.chat.onSubmit = { [unowned self] text in ask(text) }
        p.onBecomeKey = { [weak self] in if let app = self?.machine.focus.other() { self?.chatPreviousApp = app } }
        p.onResignKey = { [weak self] in self?.chatReleased() }
        p.onEscape = { [weak self] in self?.closeChat() }
        chat = p
        return p
    }

    /// Show the chat in the middle of the main screen, without taking the keyboard (`focusInput`: with it, for the Type action).
    func openChat(focusInput: Bool = false) {
        guard machine.chatOn else { return }
        let panel = chat ?? makeChat()
        if !chatOpen {
            chatOpen = true
            panel.chat.set(turns: transcript.turns)
            applyChatShade()
            machine.showChat(panel, mainVisible)
            if !askedScreen {
                askedScreen = true
                machine.askScreenAccess()  // the system's dialog, once per launch
            }
            chatLook()
        }
        if focusInput { machine.focusChat(panel) }
        refresh()
    }

    /// Re-centre it (the arrangement of the displays changed).
    func placeChat() { chat?.setFrame(ChatPanel.frame(centredOn: mainVisible), display: true) }

    /// "Close the chat": it goes away, the conversation stays for the next time. Nothing else closes it.
    func closeChat() {
        guard chatOpen else { return }
        chatOpen = false
        stopChatShading()
        chat?.makeFirstResponder(nil)
        chat?.orderOut(nil)
        chatReleased()
        endFollowUp()  // the answer it waited for a reply to is gone from the screen
        if busy || tw.pending {  // an answer is on its way: it shows on the pet's card instead, nothing is lost
            open()
            render()
        }
        refresh()
    }

    /// The text box lost the keyboard, or the chat closed: give it back to the app that had it.
    func chatReleased() {
        machine.focus.handBack(to: chatPreviousApp)
        chatPreviousApp = nil
    }

    // MARK: the conversation

    /// A request begins: the conversation is the agent's session's (a new day or persona starts it again), the answer being written is
    /// finished off, your turn and an empty turn of Robo's are added, and the chat opens.
    func chatBegin(you text: String?) {
        chatInterrupted(stopped: false, footer: chatFooter)
        transcript.reset(for: sessionID)
        retireListeningCard()
        if let text { transcript.append(.you, text) }
        transcript.append(.robo, "")
        (chatFooter, chatFailed) = ([], false)
        openChat()
        chat?.chat.endLive()
        chat?.chat.set(turns: transcript.turns)
    }

    /// An answer being written is cut short (you started speaking, or asked again): what arrived stays, marked "stopped" when the
    /// run was; an empty one goes.
    func chatInterrupted(stopped: Bool, footer: [String]) {
        guard machine.chatOn, transcript.writing else { return }
        let partial = tw.text
        if partial.isEmpty {
            transcript.dropEmptyLive()
        } else {
            transcript.seal(partial, footer: stopped && !footer.contains("stopped") ? ["stopped"] + footer : footer)
        }
        (chatFooter, chatFailed) = ([], false)
        chat?.chat.endLive()
        chat?.chat.set(turns: transcript.turns)
    }

    /// The answer is all typed: it is final, with its footer (notes opened, what the guard recorded).
    func chatSealed() {
        guard machine.chatOn, transcript.writing else { return }
        transcript.seal(tw.text, footer: chatFooter, failed: chatFailed)
        (chatFooter, chatFailed) = ([], false)
        chat?.chat.endLive()
        if chatOpen { chat?.chat.set(turns: transcript.turns) }
    }

    /// The pet's card opened to listen; the words came and went to the chat (or nothing came): the card goes, unless it has more to say.
    func retireListeningCard() {
        guard !card.isHidden, approvals.isEmpty, nudge.shown.isEmpty, card.chips.isHidden else { return }
        closeAt = 0
        fit { card.isHidden = true }
        card.clearReply()
    }

    /// What the chat says about Robo: "Listening…", "Working…" with the dots and what it is doing, "Listening for your reply".
    func refreshChat(listening now: Bool, thinking: Bool, label: String) {
        guard chatOpen, let c = chat?.chat else { return }
        let waiting = self.now() < followUntil && !busy
        c.setStatus(now ? "Listening…" : busy ? (label.isEmpty ? "Working…" : label) : waiting ? "Listening for your reply" : "")
        c.setWorking(thinking, caption: label)
    }

    /// ROBO_CHAT_DEMO=1: a made-up conversation, to look at the chat over a bright and a dark backdrop without an agent (a test copy).
    func demoChat() {
        transcript.reset(for: "demo")
        transcript.append(.you, "What is due this week?")
        transcript.append(.robo, "")
        transcript.seal("""
            Three things, newest first:

            | When | What |
            |---|---|
            | **Fri 23:59** | Problem set 4 (Linear Algebra) |
            | **Thu 14:00** | Lab 3 demo (Introduction to AI) |
            | **Tue** | Reading quiz, chapter 5 |

            The lab is the tightest one: `git log` shows two commits so far.
            """, footer: ["✓ saved · Plan.md"])
        transcript.append(.you, "Explain gradient descent in a few lines, and show a tiny example.")
        transcript.append(.robo, "")
        transcript.seal("""
            Gradient descent minimises a loss $L(w)$ by repeating one step:

            $$w_{t+1} = w_t - \\eta \\, \\nabla L(w_t)$$

            where $\\eta$ is the **learning rate**. For $L(w) = w^2$ the step is $w_{t+1} = (1 - 2\\eta)\\, w_t$, so it shrinks to zero when $0 < \\eta < 1$ and diverges when $\\eta > 1$.

            ```python
            w, lr = 5.0, 0.1
            for _ in range(50):
                w -= lr * 2 * w   # d/dw of w**2
            ```

            - Start anywhere, here $w_0 = 5$.
            - Each step multiplies $w$ by $0.8$.
            """)
        transcript.append(.you, "thanks")
        transcript.note("Sorry, I didn't catch that.")
        openChat()
    }

    // MARK: the backdrop

    /// A look at what is behind the chat, one at a time (the card's look and this one share `sampling`: a second caller of `Backdrop`
    /// would be dropped without an answer, and its flag would stay set for ever). What it reads decides the shade.
    func chatLook() {
        guard chatOpen, !sampling, let panel = chat else { return }
        sampling = true
        chatSampleAt = now() + RoboWindow.chatLookS
        let rect = panel.frame.insetBy(dx: ChatPanel.margin, dy: ChatPanel.margin)  // the glass
        machine.backdropLuma(rect) { [weak self] luma in
            guard let self else { return }
            sampling = false
            guard chatOpen, !shutdownStarted else { return }
            chatShade.see(luma: luma)
            applyChatShade()
        }
    }

    /// The glass and the panel's appearance at the shade's level, easing at 30 Hz while it moves (Reduce Motion goes straight there);
    /// a light or a dark window by the system's mode while the backdrop is not known.
    func applyChatShade() {
        guard chat != nil else { return }
        guard chatShade.known else {
            stopChatShading()
            setChatLevel(machine.systemDark() ? 0 : 1)
            return
        }
        if machine.reduceMotion() { chatShade.snap() }
        setChatLevel(chatShade.level)
        if chatShade.moving && chatShadeTimer == nil {
            chatLastShade = now()
            chatShadeTimer = commonTimer(RoboWindow.typeS) { [weak self] in self?.easeChat() }
        }
    }

    func easeChat() {
        let t = now()
        let moving = chatShade.step(dt: min(t - chatLastShade, 0.1))
        chatLastShade = t
        setChatLevel(chatShade.level)
        if !moving { stopChatShading() }
    }

    func stopChatShading() {
        chatShadeTimer?.invalidate()
        chatShadeTimer = nil
    }

    private func setChatLevel(_ level: Double) {
        guard let panel = chat else { return }
        chatLevel = level
        panel.chat.setShade(level)
        let appearance = NSAppearance(named: level >= 0.5 ? .aqua : .darkAqua)
        if panel.appearance?.name != appearance?.name { panel.appearance = appearance }  // the text and marks follow it
    }
}
