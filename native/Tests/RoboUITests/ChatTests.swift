// The chat window: a window of its own in the middle of the main screen, where your turns and Robo's answers stay as bubbles until you say
// "close the chat". The flow runs through the rig (chat on; the panel is placed but never ordered front), the views are built on their own.
// The pet's card tests run with the chat off (the rig's default) and are untouched.
import AppKit
import Foundation
import Testing
import RoboCore
import RoboSystem
@testable import RoboUI

@MainActor private func turns(_ r: Rig) -> [String] { r.window.transcript.turns.map(\.text) }
@MainActor private func roles(_ r: Rig) -> [Turn.Role] { r.window.transcript.turns.map(\.role) }
@MainActor private func bubbleCount(_ r: Rig) -> Int { r.window.chat?.chat.bubbles.count ?? 0 }
private func receipt(_ at: Double) -> String {
    #"{"ts": "\#(Usage.stamp(at))", "tool": "browser_click", "label_or_path": "Send", "host": "outlook.office.com", "ok": true}"#
}

// MARK: - the conversation in the window

@MainActor @Suite(.serialized) struct ChatWindowTests {
    @Test func askingOpensTheChatInTheMiddleOfTheMainScreenAndTheCardStaysOut() async throws {
        let r = Rig([delta("Hello "), completed("Hello **you**")], chat: true)
        defer { r.close() }
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        #expect(r.window.chatOpen && r.chats.count == 1 && r.window.card.isHidden)  // nothing of the answer on the pet's card
        let panel = try #require(r.window.chat)
        #expect(panel.frame == ChatPanel.frame(centredOn: Rig.single[0].visible))
        #expect(abs(panel.frame.midX - Rig.single[0].visible.midX) <= 0.5 && abs(panel.frame.midY - Rig.single[0].visible.midY) <= 0.5)  // whole pixels
        #expect(panel.frame.width <= ChatPanel.contentSize.width + 2 * ChatPanel.margin && !panel.isVisible)  // the rig never orders it front
        #expect(roles(r) == [.you, .robo] && turns(r) == ["hi", "Hello **you**"] && !r.window.transcript.writing)
        #expect(bubbleCount(r) == 2)
    }

    @Test func theChatIsNoBiggerThanNinetyPercentOfAnySmallScreen() {
        let small = CGRect(x: 0, y: 0, width: 400, height: 500)
        let f = ChatPanel.frame(centredOn: small)
        #expect(f.width <= 400 * 0.9 + 2 * ChatPanel.margin && f.height <= 500 * 0.9 + 2 * ChatPanel.margin && f.midX == 200 && f.midY == 250)
    }

    @Test func yourTurnIsThereAtOnceAndAnEmptyTurnOfRobosWaitsForTheAnswer() async {
        let r = Rig([.wait, completed("done")], chat: true)
        defer { r.close() }
        r.window.ask("question")
        #expect(roles(r) == [.you, .robo] && r.window.transcript.writing && turns(r)[0] == "question")
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
        #expect(turns(r) == ["question", "done"] && !r.window.transcript.writing)
    }

    @Test func aSecondRequestKeepsTheFirstConversation() async {
        let r = Rig([completed("first answer")], chat: true)
        defer { r.close() }
        r.window.ask("one")
        #expect(await pump(!r.window.busy))
        r.hermes.script = [completed("second answer")]
        r.window.ask("two")
        #expect(await pump(!r.window.busy))
        #expect(turns(r) == ["one", "first answer", "two", "second answer"] && roles(r) == [.you, .robo, .you, .robo])
        #expect(bubbleCount(r) == 4 && r.chats.count == 1)  // one window, not one per request
    }

    @Test func nothingClosesTheChatButTheCommand() async {
        let r = Rig([completed(HELLO)], chat: true)
        defer { r.close() }
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        for _ in 0..<1500 { r.step() }  // about 50 s: the card would have closed after 20
        #expect(r.window.chatOpen && r.window.closeAt == 0)
        r.window.escape()  // Esc on the pet
        r.window.closeBubble()  // the card's own close
        #expect(r.window.chatOpen)
        r.window.ask("close the chat")
        #expect(!r.window.chatOpen && !r.window.chat!.isVisible)
        #expect(r.hermes.asked.map(\.text) == ["hi"])  // the command was not a request for the agent
        #expect(turns(r) == ["hi", HELLO])  // and the conversation is kept
    }

    @Test(arguments: ["close the chat", "Please close the chat.", "hide this chat window", "Robo, dismiss the chat"])
    func theCommandSpokenOrTypedClosesTheChat(said: String) async {
        let r = Rig([completed(HELLO)], chat: true)
        defer { r.close() }
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        r.window.onHeard(said)  // spoken
        #expect(!r.window.chatOpen && r.hermes.asked.count == 1)
        r.hermes.script = [completed("hi")]
        r.window.ask("hello again")
        #expect(r.window.chatOpen)
        #expect(await pump(!r.window.busy))
        r.window.chat?.chat.onSubmit?(said)  // typed in the chat's text box
        #expect(!r.window.chatOpen)
    }

    @Test func aRequestThatOnlyMentionsClosingStillGoesToTheAgent() async {
        let r = Rig([completed("ok")], chat: true)
        defer { r.close() }
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        r.window.ask("close the Moodle tab")
        #expect(await pump(!r.window.busy))
        #expect(r.window.chatOpen && r.hermes.asked.map(\.text) == ["hi", "close the Moodle tab"])
    }

    @Test func closeWithTheChatClosedIsAnOrdinaryRequest() async {
        let r = Rig([completed("ok")], chat: true)
        defer { r.close() }
        r.window.ask("close the chat")  // nothing to close: the agent may have something to say about it
        #expect(await pump(!r.window.busy))
        #expect(r.hermes.asked.map(\.text) == ["close the chat"])
    }

    @Test func closingWhileAnAnswerIsOnItsWayShowsItOnThePetsCardAndNothingIsLost() async {
        let r = Rig([delta("partial "), .wait, delta("answer"), completed("partial answer")], chat: true)
        defer { r.close() }
        r.window.ask("question")
        #expect(await pump(r.window.tw.text == "partial "))
        r.window.ask("close the chat")
        #expect(!r.window.chatOpen && !r.window.card.isHidden)  // the card carries the rest
        #expect(r.window.card.reply.string.contains("partial"))
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
        #expect(await r.run(until: r.window.typed))
        #expect(r.window.card.reply.string == "partial answer")
        #expect(turns(r) == ["question", "partial answer"] && !r.window.transcript.writing)  // and the conversation has it
        // opened again, the chat shows the conversation
        r.window.openChat()
        #expect(r.window.chatOpen && bubbleCount(r) == 2)
    }

    @Test func theConversationStartsAgainWhenTheAgentsSessionChanges() async {
        nonisolated(unsafe) var day = CalendarDay(year: 2026, month: 10, day: 11)!
        let r = Rig([completed("a")], today: { day }, chat: true)
        defer { r.close() }
        r.window.ask("one")
        #expect(await pump(!r.window.busy))
        #expect(turns(r) == ["one", "a"])
        day = CalendarDay(year: 2026, month: 10, day: 12)!
        r.hermes.script = [completed("b")]
        r.window.ask("two")
        #expect(await pump(!r.window.busy))
        #expect(turns(r) == ["two", "b"])  // the agent's session is another one, so the chat is
    }

    // MARK: speaking, interrupting, notices

    @Test func speakingKeepsTheConversationAndThePetsCardListens() async {
        let r = Rig([completed(HELLO)], chat: true)
        defer { r.close() }
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        r.window.onEvent(.listening(true))  // Ctrl+Q held, a click on the face, a name
        #expect(r.window.chatOpen && turns(r) == ["hi", HELLO] && bubbleCount(r) == 2)
        #expect(!r.window.card.isHidden)  // the card says "listening"
        r.window.onHeard("what is due")
        #expect(r.window.card.isHidden)  // and goes when the words became a request
        #expect(await pump(!r.window.busy))
        #expect(roles(r) == [.you, .robo, .you, .robo] && turns(r)[2] == "what is due")
    }

    @Test func anAnswerCutShortKeepsWhatArrivedMarkedAsStopped() async {
        let r = Rig([delta("Hello wor"), .wait, .event(.runEnded(status: "cancelled", output: "", error: ""))], chat: true)
        defer { r.close() }
        r.window.ask("question")
        #expect(await pump(r.window.tw.text == "Hello wor"))
        r.window.onEvent(.listening(true))  // you start speaking over it
        #expect(r.window.transcript.turns.last?.text == "Hello wor" && r.window.transcript.turns.last?.footer == ["stopped"])
        #expect(!r.window.transcript.writing)
        r.hermes.gate.signal()  // the run ends
        #expect(await pump(!r.window.busy))
        #expect(turns(r) == ["question", "Hello wor"] && r.window.transcript.turns.last?.footer == ["stopped"])  // sealed once
    }

    @Test func anAnswerStoppedBeforeItsFirstWordLeavesNoEmptyBubble() async {
        let r = Rig([.wait, .event(.runEnded(status: "cancelled", output: "", error: ""))], chat: true)
        defer { r.close() }
        r.window.ask("question")
        r.window.onEvent(.listening(true))
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
        #expect(turns(r) == ["question"] && bubbleCount(r) == 1)
    }

    @Test func aQuestionAskedDuringARunInterruptsItAndBothAreInTheConversation() async {
        let r = Rig([delta("first part"), .wait, .event(.runEnded(status: "cancelled", output: "", error: ""))], chat: true)
        defer { r.close() }
        r.window.ask("one")
        #expect(await pump(r.window.tw.text == "first part"))
        r.window.ask("two")  // waits for the first run to end
        r.hermes.script = [completed("answer two")]
        r.hermes.gate.signal()
        #expect(await pump(r.hermes.asked.count == 2 && !r.window.busy))
        #expect(turns(r) == ["one", "first part", "two", "answer two"])
        #expect(r.window.transcript.turns[1].footer == ["stopped"])
    }

    @Test func aNoticeIsALineOfTheChatAndLeavesTheAnswerBeingWrittenAlone() async {
        let r = Rig([delta("working on it "), .wait, completed("working on it done")], chat: true)
        defer { r.close() }
        r.window.ask("question")
        #expect(await pump(r.window.tw.text == "working on it "))
        r.window.onNote("I lost the microphone, reconnecting...")
        #expect(turns(r) == ["question", "I lost the microphone, reconnecting...", ""])  // before the answer being written
        #expect(r.window.transcript.writing && r.window.tw.text == "working on it ")  // the typing was not reset
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
        #expect(turns(r).last == "working on it done" && !r.window.transcript.writing)
    }

    @Test func nothingHeardIsANoticeInTheChatAndTheListeningCardGoes() async {
        let r = Rig([completed(HELLO)], chat: true)
        defer { r.close() }
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        r.window.onEvent(.listening(true))
        #expect(!r.window.card.isHidden)
        r.window.onHeard("")
        #expect(turns(r) == ["hi", HELLO, "Sorry, I didn't catch that."] && r.window.card.isHidden)
    }

    // MARK: failures, footers, the digest

    @Test func aFailedRunIsAFailedTurnWithItsReason() async {
        let r = Rig(fail: BrainError("Hermes is not running"), chat: true)
        defer { r.close() }
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        #expect(await r.run(until: r.window.typed))
        let last = r.window.transcript.turns.last
        #expect(last?.text == "Hermes is not running" && last?.failed == true)
    }

    @Test func theFooterAndTheReceiptSitUnderTheAnswer() async {
        let reply = "I sent the email."
        let r = Rig([delta(reply), completed(reply)], chat: true)
        defer { r.close() }
        r.hermes.onAsk = {
            Usage.append(receipt(Date().timeIntervalSince1970), to: r.receipts)
            write([r.vault.appendingPathComponent("Drafts/Mail.md"): "Hi"])
        }
        r.window.ask("send it")
        #expect(await pump(!r.window.busy))
        #expect(r.window.transcript.turns.last?.footer == ["📓 In Obsidian: Mail", "✓ sent · outlook.office.com"])
        #expect(r.window.transcript.turns.last?.text == reply)  // the footer is not part of the answer
    }

    @Test func theMorningDigestOpensTheChatByItselfAndAnsweringItNeedsNoUserTurn() async {
        let r = Rig([completed("Today: two things.")], chat: true)
        defer { r.close() }
        r.window.ask(RoboWindow.digestPrompt, waitNetwork: true)
        #expect(await pump(!r.window.busy))
        #expect(r.window.chatOpen && roles(r) == [.robo] && turns(r) == ["Today: two things."])
    }

    @Test func theMenuDigestShowsADigestTurn() async {
        let r = Rig([completed("Today: two things.")], chat: true)
        defer { r.close() }
        r.window.ask(RoboWindow.digestPrompt)
        #expect(await pump(!r.window.busy))
        #expect(turns(r) == ["📚 School digest", "Today: two things."])
    }

    // MARK: the pet and the rest of the window

    @Test func theTypeActionOpensTheChatAndTakesTheTextBox() {
        let r = Rig(chat: true)
        defer { r.close() }
        r.window.typeText()
        #expect(r.window.chatOpen && r.chatFocuses == 1 && r.typers.isEmpty)  // not the small Type window
        r.window.typeText()
        #expect(r.chats.count == 1 && r.chatFocuses == 2)  // the same window, not placed again
    }

    @Test func withTheChatOffTheTypeActionIsTheSmallWindow() {
        let r = Rig()
        defer { r.close() }
        r.window.typeText()
        #expect(!r.window.chatOpen && r.typers.count == 1 && r.chatFocuses == 0)
    }

    @Test func theTextBoxSendsLikeAnyOtherRequest() async {
        let r = Rig([completed("fine")], chat: true)
        defer { r.close() }
        r.window.openChat()
        r.window.chat?.chat.onSubmit?("typed in the chat")
        #expect(await pump(!r.window.busy))
        #expect(r.hermes.asked.map(\.text) == ["typed in the chat"] && turns(r) == ["typed in the chat", "fine"])
    }

    @Test func theTextBoxTakesFocusAcceptsTypingAndSendsIt() async {
        let r = Rig([completed("fine")], chat: true)
        defer { r.close() }
        r.window.openChat()
        let panel = r.window.chat!
        panel.setFrame(CGRect(x: 100_000, y: 100_000, width: 532, height: 652), display: false)  // far from every display, like the pet's keyboard tests
        panel.orderFrontRegardless()
        panel.makeKey()
        defer { panel.orderOut(nil) }
        #expect(panel.isKeyWindow)  // needs an unlocked screen
        panel.chat.focusInput()
        #expect(panel.inputActive && r.window.nudgeHeld)  // a nudge waits while you type
        panel.chat.input.currentEditor()?.insertText("typed hello")
        #expect(panel.chat.input.stringValue == "typed hello")
        panel.chat.input.sendAction(panel.chat.input.action, to: panel.chat.input.target)  // Return
        #expect(panel.chat.input.stringValue.isEmpty)
        #expect(await pump(!r.window.busy))
        #expect(r.hermes.asked.map(\.text) == ["typed hello"] && turns(r) == ["typed hello", "fine"])
    }

    @Test func afterAnAnswerInTheChatYouCanReplyWithoutSayingRobo() async {
        let r = Rig([completed(HELLO)], chat: true)
        defer { r.close() }
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        #expect(await r.run(until: r.window.typed))
        #expect(r.ear.follow == RoboWindow.followUpS && r.window.followUntil > 0)  // the key-less window is open
        for _ in 0..<150 { r.step() }  // 5 s: the card's timer would have run, and ended it with the card
        #expect(r.window.followUntil > r.window.now())
    }

    @Test func thePetIsCalledOnlyWhileItWorksAndTheChatDoesNotHoldItInACorner() async {
        let r = Rig([.wait, completed(HELLO)], chat: true)
        defer { r.close() }
        r.window.ask("hi")
        #expect(r.window.busy)  // working: the pet is called
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
        #expect(r.window.chatOpen && r.window.card.isHidden)  // the card is out, so "called" (`busy || card shown`) is false again
    }

    @Test func aNudgeIsNotHeldByAChatThatIsOnlyOpen() async {
        let r = Rig([completed(HELLO)], chat: true)
        defer { r.close() }
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        #expect(await r.run(until: r.window.typed))
        for _ in 0..<600 { r.step() }  // the follow-up window is over
        #expect(r.window.chatOpen && !r.window.nudgeHeld)
    }

    // MARK: called: the pet goes to a side, the background is blurred a little

    @Test func theBackgroundIsBlurredWhileRoboIsCalledAndWhileTheChatIsUp() async {
        let r = Rig([completed(HELLO)], chat: true)
        defer { r.close() }
        #expect(r.blurs.isEmpty)
        r.window.onEvent(.listening(true))  // Ctrl+Q held
        #expect(r.blurs.last?.on == true && r.blurs.last?.frame == Rig.single[0].frame)  // the main display, all of it
        r.window.onHeard("")  // nothing was said: not called any more
        #expect(r.blurs.last?.on == false)
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        #expect(r.blurs.last?.on == true && r.blurs.count == 3)  // the chat is up
        for _ in 0..<600 { r.step() }
        #expect(r.blurs.count == 3)  // switched on once, not on every tick
        r.window.ask("close the chat")
        #expect(r.blurs.last?.on == false)
    }

    @Test func noBlurWithoutTheChat() {
        let r = Rig()
        defer { r.close() }
        r.window.onEvent(.listening(true))
        r.window.say("x")
        #expect(r.blurs.isEmpty)
    }

    @Test func thePetGoesToTheMiddleOfTheNearestSideAndStaysWhileTheChatIsUpThenIsFreeAgain() async {
        let r = Rig([completed(HELLO)], chat: true)
        defer { r.close() }
        let screen = r.window.roamer.screens[0]
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        for _ in 0..<600 {  // 20 s
            r.clock.advance(1.0 / 30)
            r.window.roam()
        }
        let roamer = r.window.roamer
        #expect(roamer.mode == .come)  // called, and staying
        let middle = screen.y + (screen.h - roamer.size.y) / 2
        #expect(abs(roamer.pos.y - middle) <= 1)  // the middle of the side
        let atLeft = abs(roamer.pos.x - (screen.x + Roam.edge)) <= 1, atRight = abs(roamer.pos.x - (screen.x + screen.w - roamer.size.x - Roam.edge)) <= 1
        #expect(atLeft || atRight)  // a side, not a corner and not the middle of the screen
        let before = roamer.pos
        for _ in 0..<300 {
            r.clock.advance(1.0 / 30)
            r.window.roam()
        }
        #expect(roamer.pos == before)  // it stays put while the chat is up
        r.window.ask("close the chat")
        for _ in 0..<300 {
            r.clock.advance(1.0 / 30)
            r.window.roam()
        }
        #expect(roamer.mode != .come)  // free again: it rests and drifts
    }

    @Test func withoutTheChatACallStillGoesToACorner() async {
        let r = Rig([completed(HELLO)])
        defer { r.close() }
        #expect(!r.window.roamer.callToSide)
    }

    @Test func theChatIsClosedWhenTheAppQuits() async {
        let r = Rig(chat: true)
        defer { r.close() }
        r.window.openChat()
        r.window.shutdown {}
        #expect(r.window.chat?.isVisible == false)
    }
}

// MARK: - what is behind the glass

@MainActor @Suite(.serialized) struct ChatShadeTests {
    @Test func theGlassTurnsLightOverADarkScreenAndDarkOverALightOneAndThePanelsAppearanceFollows() async {
        let r = Rig(chat: true)
        defer { r.close() }
        r.backdrop = 0.1  // a dark screen
        r.window.openChat()
        #expect(r.window.chatLevel == 1 && r.window.chat?.appearance?.name == .aqua)  // a light chat
        r.backdrop = 0.9
        #expect(await r.run(until: r.window.chatLevel == 0))
        #expect(r.window.chat?.appearance?.name == .darkAqua && r.window.chat?.chat.glass.level == 0)
        r.backdrop = 0.1
        #expect(await r.run(until: r.window.chatLevel == 1))
        #expect(r.window.chat?.appearance?.name == .aqua)
    }

    @Test func withoutTheScreenRecordingPermissionItFollowsTheSystemsMode() {
        let r = Rig(chat: true)
        defer { r.close() }
        r.backdrop = nil
        r.systemDark = true
        r.window.openChat()
        #expect(r.window.chatLevel == 0 && r.window.chat?.appearance?.name == .darkAqua)
        r.systemDark = false
        r.window.applyChatShade()
        #expect(r.window.chatLevel == 1 && r.window.chat?.appearance?.name == .aqua)
    }

    @Test func itLooksAtTheGlassRectangleOfTheChatAndOnlyWhileOpen() async {
        let r = Rig(chat: true)
        defer { r.close() }
        r.backdrop = 0.5
        r.window.openChat()
        let glass = r.window.chat!.frame.insetBy(dx: ChatPanel.margin, dy: ChatPanel.margin)
        #expect(r.looks.last == glass)
        r.window.ask("close the chat")
        let looks = r.looks.count
        for _ in 0..<150 { r.step() }
        #expect(r.looks.count == looks)  // closed: no look
    }

    @Test func theCardAndTheChatTakeTurnsAtTheBackdropAndNeitherStaysStuck() async {
        let r = Rig(chat: true)
        defer { r.close() }
        r.backdrop = 0.5
        r.holdLooks = true
        r.window.openChat()  // its look is held
        r.window.open()  // the pet's card opens too and wants a look
        #expect(r.looks.count == 1)  // one at a time
        r.answerLooks(0.5)
        for _ in 0..<12 { r.step() }
        #expect(r.looks.count >= 2)  // the other had its turn
        r.holdLooks = false
        r.answerLooks(0.5)
        for _ in 0..<90 { r.step() }
        #expect(!r.window.sampling)  // never stuck
    }
}

// MARK: - the views on their own

@MainActor @Suite(.serialized) struct ChatViewTests {
    private func view(_ t: Transcript, size: CGSize = CGSize(width: 532, height: 652)) -> ChatView {
        _ = NSApplication.shared
        let v = ChatView(theme: Themes.glass, reduceMotion: { true })
        v.setFrameSize(size)
        v.layoutSubtreeIfNeeded()
        v.set(turns: t.turns)
        v.layoutSubtreeIfNeeded()
        return v
    }

    private func conversation() -> Transcript {
        var t = Transcript()
        t.append(.you, "hi")
        t.append(.robo, "")
        t.seal("Hello there. This is a reply that is a little longer than the question was.")
        t.append(.robo, "")
        t.seal("And a second bubble from Robo.", footer: ["✓ sent · outlook.office.com"])
        t.append(.you, "thanks")
        return t
    }

    @Test func yoursAreOnTheRightRobosOnTheLeftAndNoWiderThanTheShareOfTheColumn() {
        let t = conversation()
        let v = view(t)
        let you = v.bubbles[t.turns[0].id]!, robo = v.bubbles[t.turns[1].id]!
        let column = v.bounds.width - 2 * ChatPanel.margin
        #expect(you.frame.midX > column / 2 && robo.frame.midX < column / 2)
        #expect(robo.bubbleSize.width <= ((column - 2 * ChatView.side) * ChatView.widthShare).rounded(.down) + 0.5)
        #expect(you.bubbleSize.width < robo.bubbleSize.width)  // yours shrinks to its two letters
        #expect(you.frame.maxX <= v.bounds.width && robo.frame.minX >= 0)  // the tail room is inside the window
    }

    @Test func onlyTheLastBubbleOfARunHasATailAndTheRowsDoNotOverlap() {
        let t = conversation()
        let v = view(t)
        let b = t.turns.map { v.bubbles[$0.id]! }
        #expect(b.map(\.tail) == [true, false, true, true])  // you | robo robo | you
        for (a, c) in zip(b, b.dropFirst()) { #expect(a.frame.maxY <= c.frame.minY) }
    }

    @Test func aFooterIsUnderItsBubbleAndInTheRowsHeight() {
        let t = conversation()
        let v = view(t)
        let bubble = v.bubbles[t.turns[2].id]!
        #expect(bubble.frame.height > bubble.bubbleSize.height + 8)
    }

    @Test func theTypingDotsShowOnlyInATurnWithNoTextYet() {
        var t = Transcript()
        t.append(.you, "hi")
        t.append(.robo, "")
        let v = view(t)
        v.setWorking(true, caption: "searching the web…")
        #expect(v.bubbles[t.turns[1].id]?.dots != nil && v.bubbles[t.turns[0].id]?.dots == nil)
        v.setLive(markdown: "First words", hidden: 0)
        #expect(v.bubbles[t.turns[1].id]?.dots == nil)  // the text replaced them
        v.setWorking(false, caption: "")
        #expect(v.bubbles.values.allSatisfy { $0.dots == nil })
    }

    @Test func theLiveBubbleGrowsWithTheTextAndTheChatFollowsTheEnd() {
        var t = Transcript()
        t.append(.you, "tell me a lot")
        t.append(.robo, "")
        let v = view(t)
        let id = t.turns[1].id
        let before = v.bubbles[id]!.frame.height
        let words = (0..<400).map { "word\($0)" }.joined(separator: " ")
        v.setLive(markdown: words, hidden: 0)
        v.layoutSubtreeIfNeeded()
        #expect(v.bubbles[id]!.frame.height > before + 100)
        #expect(v.following)
        let visible = v.scroll.contentView.bounds
        let docHeight = v.scroll.documentView!.frame.height
        #expect(abs(visible.maxY - docHeight) < 1)  // at the end
    }

    @Test func aReaderWhoScrolledUpIsLeftWhereTheyAre() {
        var t = Transcript()
        for i in 0..<12 {
            t.append(.you, "question \(i)")
            t.append(.robo, "")
            t.seal("An answer to the question that wraps over a couple of lines so that the conversation is taller than the window shows. \(i)")
        }
        let v = view(t)
        #expect(v.following)
        v.scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))  // the reader goes to the top
        v.scroll.reflectScrolledClipView(v.scroll.contentView)
        #expect(!v.following)
        t.append(.you, "one more")
        v.set(turns: t.turns)
        #expect(v.scroll.contentView.bounds.minY == 0)  // not pulled to the end
        v.scroll.contentView.scroll(to: NSPoint(x: 0, y: v.scroll.documentView!.frame.height))  // and back at the bottom
        v.scroll.reflectScrolledClipView(v.scroll.contentView)
        #expect(v.following)
    }

    @Test func theTextIsTheSystemsOwnColourWhateverTheCardsInkIs() {
        Chrome.ink = 1
        defer { Chrome.ink = nil }
        let chat = Markdown.attributed("hello `code`", theme: Themes.glass, ink: nil)
        let card = Markdown.attributed("hello `code`", theme: Themes.glass)
        let a = chat.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let b = card.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(a == NSColor.labelColor && b != NSColor.labelColor)  // the card's ink is baked in, the chat's is not
    }

    @Test func aLongAnswerKeepsItsMarkdownInsideTheBubble() {
        var t = Transcript()
        t.append(.robo, "")
        t.seal("# Plan\n\n**10:45-12:15** study\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```\ncode line\n```")
        let v = view(t)
        let bubble = v.bubbles[t.turns[0].id]!
        #expect(bubble.text.string.contains("study") && bubble.text.string.contains("code line"))
        #expect(bubble.text.contentHeight > 80 && bubble.text.frame.maxX <= bubble.bounds.maxX)
    }

    @Test func aTurnThatLeftTheConversationLosesItsBubble() {
        var t = conversation()
        let v = view(t)
        #expect(v.bubbles.count == 4)
        t = Transcript()
        t.append(.you, "fresh start")
        v.set(turns: t.turns)
        #expect(v.bubbles.count == 1 && v.scroll.documentView?.subviews.count == 1)
    }
}

// MARK: - the blur of the background

@MainActor @Suite struct BlurPictureTests {
    private func stripes(_ w: Int, _ h: Int) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<h {
            (y / 5 % 2 == 0 ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)).setFill_(ctx, CGRect(x: 0, y: y, width: w, height: 1))
        }
        return ctx.makeImage()!
    }

    private func gray(_ image: CGImage, x: Int, y: Int) -> Int {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return Int(p[(y * image.width + x) * 4])
    }

    @Test func aBlurKeepsTheSizeSoftensTheEdgesAndLeavesTheMiddleOfAStripe() throws {
        let image = stripes(60, 60)
        let blurred = try #require(Backdrop.blurred(image, sigma: Backdrop.blurSigma))
        #expect(blurred.width == 60 && blurred.height == 60)
        // rows 0-4 are one colour and 5-9 the other: at the boundary (row 4/5, from the top of the bitmap) the blur is a grey, not black or white
        let edge = gray(blurred, x: 30, y: 4)
        #expect(edge > 20 && edge < 235)
        let before = gray(image, x: 30, y: 4)
        #expect(before == 0 || before == 255)
        #expect(Backdrop.blurSigma > 0 && Backdrop.blurSigma <= 2)  // "a little": a sigma of a pixel or two at half size
    }
}

private extension CGColor {
    func setFill_(_ ctx: CGContext, _ rect: CGRect) {
        ctx.setFillColor(self)
        ctx.fill(rect)
    }
}
