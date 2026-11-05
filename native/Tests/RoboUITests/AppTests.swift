// The conversation, with a fake agent, a fake ear and a temp home (the rig is in TestRig.swift).
import AppKit
import Foundation
import Testing
import RoboCore
import RoboSystem
@testable import RoboUI

let HELLO = "Hello there, this is a short reply."
let LONG = (0..<45).map { "word\($0)" }.joined(separator: " ")  // about 250 characters: seconds to type
func completed(_ text: String) -> FakeAgent.Step { .event(.runEnded(status: "completed", output: text)) }
func delta(_ text: String) -> FakeAgent.Step { .event(.delta(text)) }

/// What the window shows of the reply now: the typewriter's view (Markdown, as the card gets it).
@MainActor func shown(_ r: Rig) -> String { r.window.tw.view().markdown }

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var value: Bool { get { lock.withLock { on } } set { lock.withLock { on = newValue } } }
}

// MARK: - asking the agent

@MainActor @Suite(.serialized) struct AskTests {
    @Test func theReplyStreamsWithoutTagsAndReturnsToIdle() async {
        let r = Rig([.event(.feeling("happy")), delta("Hel"), delta("lo **you**"), completed("Hello **you**")])
        defer { r.close() }
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        #expect(r.agent.asked.map(\.text) == ["hi"] && r.agent.asked[0].session == r.window.sessionID)
        #expect(shown(r) == "Hello **you**" && !shown(r).contains("[["))
        #expect(r.window.mind.activity == .idle && r.window.mind.emotion == "happy")
    }

    @Test func aBrainErrorShowsItsMessageAndASadFace() async {
        let r = Rig(fail: BrainError("The agent is not running"))
        defer { r.close() }
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        #expect(shown(r) == "The agent is not running")  // no generic prefix
        #expect(r.window.mind.activity == .error)
    }

    @Test func anOtherErrorNeverLeavesTheWindowBusy() async {
        struct Odd: Error {}
        let r = Rig(fail: Odd())
        defer { r.close() }
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        #expect(shown(r).hasPrefix("Something went wrong:"))
    }

    @Test func aFailedRunPokesTheHealthPoller() async {
        let r = Rig(fail: BrainError("The agent is not running"), health: "http://127.0.0.1:9")
        defer { r.close() }
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        #expect(r.pollers[0].poked == 1)
        let quiet = Rig()  // no agent url: no poller at all
        defer { quiet.close() }
        #expect(quiet.window.poller == nil && quiet.pollers.isEmpty)
    }

    @Test func aQuestionDuringARunWaitsForIt() async {
        let r = Rig([.wait, completed("ok")])
        defer { r.close() }
        r.window.ask("news?")
        #expect(await pump(!r.agent.asked.isEmpty))
        r.window.ask("second while busy")  // one run at a time: it is asked when this one ends
        r.agent.gate.signal()
        #expect(await pump(r.agent.asked.count == 2))
        #expect(r.agent.asked.map(\.text) == ["news?", "second while busy"])
        r.agent.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    @Test(arguments: ["failed", "cancelled"])
    func aRunThatDidNotCompleteSaysWhatHappened(status: String) async {
        let r = Rig([.event(.runEnded(status: status, error: status == "failed" ? "boom" : ""))])
        defer { r.close() }
        r.window.ask("go")
        #expect(await pump(!r.window.busy))
        #expect(shown(r) == (status == "failed" ? "boom" : "Run cancelled."))
    }

    @Test func escapeStopsTheRun() async {
        let r = Rig([delta("long"), .wait, .event(.runEnded(status: "cancelled"))])
        defer { r.close() }
        r.window.ask("go")
        #expect(await pump(r.window.mind.activity == .talking))
        r.window.stop()
        #expect(await pump(r.agent.stopped == ["run_1"]))
        r.agent.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    // MARK: stopping

    @Test func stopBeforeTheRunExistsStopsItOnceStarted() async {
        let r = Rig([.event(.runEnded(status: "cancelled"))])
        r.agent.beforeStart = Gate()
        defer { r.close() }
        r.window.ask("go")
        #expect(await pump(!r.agent.asked.isEmpty))
        r.window.stop()  // no run id yet
        r.agent.beforeStart?.signal()
        #expect(await pump(!r.window.busy))
        #expect(await pump(r.agent.stopped == ["run_1"]))
    }

    /// A stop that comes before the worker has begun: the agent is never asked.
    @Test func aStopBeforeTheWorkerBeginsNeverAsksTheAgent() async {
        let r = Rig([completed("never")])
        defer { r.close() }
        r.window.busy = true
        r.window.stop()
        await r.window.work("go", session: "s")
        #expect(await pump(!r.window.busy))
        #expect(r.agent.asked.isEmpty && r.window.mind.activity == .idle)
    }

    @Test func closingMidRunStopsIt() async {
        let r = Rig([delta("x"), .wait, .event(.runEnded(status: "cancelled"))])
        defer { r.close() }
        r.window.ask("go")
        #expect(await pump(r.window.mind.activity == .talking))
        r.window.quit()
        #expect(await pump(r.terminated))
        #expect(r.agent.stopped.first == "run_1")
        r.agent.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    // MARK: sessions

    @Test func theSessionFollowsTheDate() async {
        var d = Rig.day
        let r = Rig([completed("ok")], today: { d })
        defer { r.close() }
        r.window.ask("a")
        #expect(await pump(!r.window.busy))
        d = CalendarDay(year: 2026, month: 10, day: 12)!
        r.window.ask("b")
        #expect(await pump(!r.window.busy))
        #expect(r.agent.asked.map(\.session) == ["robo-2026-10-11", "robo-2026-10-12"])
    }

    @Test func theSessionCarriesThePersonaStamp() async {
        let r = Rig([completed("ok")], persona: "ab12cd34")
        defer { r.close() }
        r.window.ask("a")
        #expect(await pump(!r.window.busy))
        #expect(r.agent.asked[0].session == "robo-2026-10-11-ab12cd34")
    }

    // MARK: nothing unasked

    /// No digest, no scan: nothing but you asks the agent anything, at launch or later.
    @Test func aFreshWindowAsksTheAgentNothing() async {
        let r = Rig([completed("never")])
        defer { r.close() }
        _ = await pump(timeout: 0.3)
        for _ in 0..<300 { r.step() }
        r.clock.advance(86_400)  // a day later
        r.window.tick()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)  // and the Mac woke up
        _ = await pump(timeout: 0.2)
        #expect(r.agent.asked.isEmpty && !r.window.busy && r.window.card.isHidden && r.window.tw.text.isEmpty)
    }

    @Test func anAnswerIsFollowedByNothingUnasked() async {
        let r = Rig([completed("ok")])
        defer { r.close() }
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        r.clock.advance(86_400)  // the next day: the session would be new, nothing starts one
        r.window.tick()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        _ = await pump(timeout: 0.2)
        #expect(r.agent.asked.map(\.text) == ["hi"] && !r.window.busy)
    }

    // MARK: the quote

    @Test func theQuoteShowsWhatYouSaid() async {
        let r = Rig([completed("ok")])
        defer { r.close() }
        r.window.ask("what's due?")
        #expect(await pump(!r.window.busy))
        #expect(r.window.card.heardShown == "what's due?" && !r.window.card.followUpShown)  // the first question is no follow-up
    }

    @Test func aQuestionWhileTheAnswerIsUpOrJustWasIsMarkedAsAFollowUp() async {
        let r = Rig([completed("It's 3 pm.")])
        defer { r.close() }
        r.window.ask("what time is it")
        #expect(await pump(!r.window.busy))
        r.window.ask("and in Tokyo?")  // the answer is on screen
        #expect(r.window.card.followUpShown)
        #expect(await pump(!r.window.busy))
        r.window.closeBubble()
        r.window.answeredAt = r.clock.now() - RoboWindow.followUpS - 1  // long ago, card gone
        r.window.ask("what about London?")
        #expect(!r.window.card.followUpShown)
        #expect(await pump(!r.window.busy))
        r.window.closeBubble()
        r.window.answeredAt = r.clock.now() - 2  // the card closed, but a moment ago
        r.window.ask("and Paris?")
        #expect(r.window.card.followUpShown)
    }

    @Test func aLongQuestionIsShownInFullAndTheWindowStaysOnScreen() async {
        let r = Rig([completed("ok")])
        defer { r.close() }
        let question = (0..<400).map { "word\($0)" }.joined(separator: " ")
        r.window.ask(question)
        #expect(r.window.card.heardShown == question)  // nothing cut
        #expect(await pump(!r.window.busy))
        #expect(r.frame.height <= 875)
    }
}

// MARK: - the working label

@MainActor @Suite(.serialized) struct WorkingLabelTests {
    @Test func theLabelSaysOnItAtSendAndGoesAtTheEnd() async {
        let r = Rig([.wait, completed("ok")])
        defer { r.close() }
        r.window.ask("news?")
        #expect(r.window.card.statusShown == "on it…" && r.window.card.dotsShown)
        r.agent.gate.signal()
        #expect(await pump(!r.window.busy))
        #expect(r.window.card.statusShown == "" && !r.window.card.dotsShown)
        r.agent.script = [.wait, completed("again")]
        r.window.ask("again")
        #expect(r.window.card.statusShown == "on it…")
        r.agent.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    @Test func after40SecondsItSaysHowLongEvery20() async {
        let r = Rig([.wait, completed("ok")])
        defer { r.close() }
        r.window.ask("go")
        for (elapsed, want) in [(39.0, "on it…"), (1.0, "still working · 40 s"), (19.0, "still working · 40 s"),
                                (1.0, "still working · 60 s"), (35.0, "still working · 80 s"), (60.0, "still working · 140 s")] {
            r.clock.advance(elapsed)
            r.window.tick()
            #expect(r.window.card.statusShown == want)
        }
        r.agent.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    @Test func theTypingOfTheReplyReplacesTheLabel() async {
        let r = Rig([delta("Hello"), .wait, completed("Hello")])
        defer { r.close() }
        r.window.ask("go")
        #expect(await pump(shown(r) == "Hello"))
        r.clock.advance(50)
        r.window.tick()
        #expect(r.window.card.statusShown == "" && !r.window.card.dotsShown)  // text is on screen: no status row
        r.agent.gate.signal()
        #expect(await pump(!r.window.busy))
    }
}

// MARK: - voice

@MainActor @Suite(.serialized) struct VoiceTests {
    @Test func theWakeWordListensThenTheHeardTextIsAsked() async {
        let r = Rig([completed("ok")])
        defer { r.close() }
        r.ear.onWake()
        #expect(await pump(r.window.mind.activity == .listening))
        #expect(!r.window.card.isHidden && r.window.card.statusShown == "listening")
        r.ear.onText("what's on my calendar today")
        #expect(await pump(!r.agent.asked.isEmpty))
        #expect(r.agent.asked[0].text == "what's on my calendar today")
        #expect(await pump(!r.window.busy))
    }

    @Test func nothingHeardSaysSoWithoutAsking() async {
        let r = Rig()
        defer { r.close() }
        r.ear.onWake()
        r.ear.onText("")
        #expect(await pump(r.window.tw.text.contains("didn't catch")))
        #expect(r.agent.asked.isEmpty && r.window.mind.activity == .idle)
    }

    @Test func aWakeWhileAnsweringInterrupts() async {
        let r = Rig([delta("long answer"), .wait, .event(.runEnded(status: "cancelled"))])
        defer { r.close() }
        r.window.ask("tell me a story")
        #expect(await pump(r.window.mind.activity == .talking))
        r.ear.onWake()
        #expect(await pump(r.agent.stopped == ["run_1"]))
        r.agent.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    @Test func speakingOverAnAnswerAsksTheNewQuestion() async {
        let r = Rig([delta("long"), .wait, .event(.runEnded(status: "cancelled"))])
        defer { r.close() }
        r.window.ask("tell me a story")
        #expect(await pump(r.window.mind.activity == .talking))
        r.ear.onWake()
        #expect(await pump(r.agent.stopped == ["run_1"]))
        r.agent.gate.signal()  // the old run ends while robo is still listening
        #expect(await pump(!r.window.busy))
        #expect(r.window.mind.activity == .listening && !r.window.tw.text.contains("cancelled"))
        r.agent.script = [completed("ok")]
        r.ear.onText("what's due")
        #expect(await pump(r.agent.asked.map(\.text) == ["tell me a story", "what's due"]))
    }

    @Test func aQuestionHeardDuringARunWaitsForIt() async {
        let r = Rig([delta("x"), .wait, completed("x")])
        defer { r.close() }
        r.window.ask("first")
        #expect(await pump(r.window.mind.activity == .talking))
        r.ear.onText("second")  // heard while the first still runs (its stop is on the way)
        r.agent.script = [completed("second done")]
        r.agent.gate.signal()
        #expect(await pump(r.agent.asked.map(\.text) == ["first", "second"]))
    }

    @Test func aListenerErrorEndsListening() async {
        let r = Rig()
        defer { r.close() }
        r.ear.onWake()
        #expect(await pump(r.window.mind.activity == .listening))
        r.ear.onNote("Voice input stopped: device unplugged")
        #expect(await pump(r.window.mind.activity == .idle))
        #expect(r.window.tw.text.contains("unplugged") && r.window.noted)  // the MIC light shows it
        r.ear.onWake()  // listening again clears the problem
        #expect(await pump(r.window.mind.activity == .listening && !r.window.noted))
    }

    @Test func withoutAListenerThereIsNoEarAndClickingTypes() async {
        let r = Rig(listener: false, chat: true)
        defer { r.close() }
        #expect(r.window.ear == nil)
        r.window.clicked()
        #expect(r.chatFocuses == 1)
    }

    @Test func aClickListensAtOnceAndNothingSaidGoesBackToIdle() async {
        let r = Rig()
        defer { r.close() }
        r.window.clicked()
        #expect(r.ear.now == 1 && r.window.mind.activity == .listening)  // visible at once
        #expect(!r.window.card.isHidden && r.window.card.statusShown == "listening")
        r.ear.onText("")  // nothing said
        #expect(await pump(r.window.mind.activity == .idle))
    }

    @Test func aClickWhileAnsweringInterruptsAndListens() async {
        let r = Rig([delta("long"), .wait, .event(.runEnded(status: "cancelled"))])
        defer { r.close() }
        r.window.ask("story")
        #expect(await pump(r.window.mind.activity == .talking))
        r.window.clicked()
        #expect(await pump(r.agent.stopped == ["run_1"]) && r.ear.now == 1)
        r.agent.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    /// Whether the ear was ever told to listen for a reply without the name (a 0 only closes it).
    private func opened(_ r: Rig) -> Bool { r.ear.follows.contains { $0 > 0 } }

    @Test func afterAnAnswerRoboListensForAReplyWithoutItsName() async {
        let r = Rig([completed("It's 3 pm.")])
        defer { r.close() }
        r.window.ask("what time is it")
        #expect(await pump(!r.window.busy))
        #expect(RoboWindow.followUpS == 15)
        #expect(r.ear.follow == RoboWindow.followUpS)  // typed at once: the window opens at once
        #expect(r.window.followUntil == r.window.typedAt + RoboWindow.followUpS)
    }

    @Test func theFollowUpWindowCountsFromTheLastLetterNotFromTheEndOfTheRun() async {
        let r = Rig([delta(LONG), completed(LONG)], cps: 55)
        defer { r.close() }
        let w = r.window!
        w.ask("count to forty-five")
        #expect(await r.run(until: !w.busy && w.tw.pending))  // The agent is done, the letters are still coming
        #expect(!opened(r) && w.followUntil == 0 && w.followDue)  // typing does not eat the window
        #expect(w.card.header.mic.state != .hot)
        #expect(await r.run(until: w.typed))
        #expect(r.ear.follow == RoboWindow.followUpS && w.followUntil == w.typedAt + RoboWindow.followUpS)
        #expect(!w.followDue && w.card.header.mic.state == .hot)  // "Listening" while it waits for a reply
        r.clock.advance(RoboWindow.followUpS - 1)
        w.tick()
        #expect(w.card.header.mic.state == .hot)
        r.clock.advance(2)
        w.tick()
        #expect(w.card.header.mic.state == .ok)  // the window is over
    }

    @Test func aNewQuestionEndsTheFollowUpWindow() async {
        let r = Rig([completed("It's 3 pm.")])
        defer { r.close() }
        r.window.ask("what time is it")
        #expect(await pump(!r.window.busy))
        #expect(r.window.followUntil > 0)
        r.window.ask("and in Tokyo?")
        #expect(r.ear.follows.last == 0 && r.window.followUntil == 0)  // cancelled before the new answer re-opens it
    }

    @Test func closingTheCardEndsTheFollowUpWindow() async {
        let r = Rig([completed("It's 3 pm.")])
        defer { r.close() }
        r.window.ask("what time is it")
        #expect(await pump(!r.window.busy))
        #expect(r.window.card.header.mic.state == .hot)
        r.window.closeBubble()
        r.window.refresh()
        #expect(r.ear.follows.last == 0 && r.window.followUntil == 0 && r.window.card.header.mic.state == .ok)
    }

    @Test(arguments: ["failed", "cancelled"])
    func anAnswerThatDidNotCompleteOpensNoFollowUp(status: String) async {
        let r = Rig([.event(.runEnded(status: status, error: status == "failed" ? "offline" : ""))])
        defer { r.close() }
        r.window.ask("x")
        #expect(await pump(!r.window.busy))
        #expect(!opened(r) && r.window.followUntil == 0 && !r.window.followDue)
    }

    @Test func aLocalMessageOrAMicNoteOpensNoFollowUp() async {
        let r = Rig()
        defer { r.close() }
        r.window.say("Sorry, I didn't catch that.")
        #expect(r.window.typed && !opened(r) && r.window.followUntil == 0)
        r.ear.onNote("Voice input stopped: device unplugged")  // the listener's thread, through the bridge
        #expect(await pump(r.window.tw.text.contains("unplugged")))
        #expect(r.window.typed && !opened(r) && r.window.followUntil == 0)
    }

    @Test func aMicNoteWhileTheAnswerTypesCancelsItsFollowUp() async {
        let r = Rig([delta(LONG), completed(LONG)], cps: 55)
        defer { r.close() }
        let w = r.window!
        w.ask("count")
        #expect(await r.run(until: !w.busy && w.tw.pending && w.followDue))
        w.onNote("I lost the microphone, reconnecting...")  // replaces the answer
        #expect(!w.followDue)
        #expect(await r.run(until: w.typed))
        #expect(!opened(r) && w.followUntil == 0)
    }

    /// Nothing can act on the world, so what is said in the key-less follow-up window is simply taken, whatever it asks for.
    @Test(arguments: [("send it to Anna", true), ("what is due tomorrow", true), ("send it to Anna", false)])
    func aSentenceIsSentWithOrWithoutTheKey(said: String, handsFree: Bool) async {
        let r = Rig([completed("ok")])
        defer { r.close() }
        if !handsFree { r.ear.onWake() }  // the listener wakes robo itself for a held key or a click, never in a follow-up window
        r.ear.handsFree = handsFree  // the listener sets it before it delivers the text
        r.ear.onText(said)
        #expect(await pump(r.agent.asked.map(\.text) == [said]))
        #expect(await pump(!r.window.busy))
        #expect(r.window.card.heardShown == said && shown(r) == "ok" && r.window.mind.activity == .idle)
    }

    @Test(arguments: [true, false])
    func aHeldKeyOrAClickThenTheWordsAsksThem(key: Bool) async {
        let hotkey = Hotkey()  // not registered: the test calls what the system would
        let r = Rig([completed("ok")], hotkey: hotkey)
        defer { r.close() }
        if key { hotkey.onDown() } else { r.window.clicked() }
        #expect((key ? r.ear.holds : r.ear.now) == 1 && r.window.mind.activity == .listening)
        if key { hotkey.onUp() }
        #expect(r.ear.releases == (key ? 1 : 0))
        r.ear.onText("send it to Anna")
        #expect(await pump(r.agent.asked.map(\.text) == ["send it to Anna"]))
        #expect(await pump(!r.window.busy))
    }

    /// A sentence in the window starts a new exchange the way a wake does: the last reply and the window are over, and it is asked.
    @Test(arguments: [false, true])
    func aHandsFreeSentenceInTheFollowUpWindowIsANewRequest(chat: Bool) async {
        let r = Rig([completed("Your quiz is on Friday.")], chat: chat)
        defer { r.close() }
        let w = r.window!
        w.ask("when is the quiz")
        #expect(await r.run(until: w.typed && w.followUntil > 0))
        r.agent.script = [.wait, completed("Sent.")]
        r.ear.handsFree = true  // said in the window: the listener delivers it with no wake
        r.ear.onText("send it to Anna")
        #expect(await pump(r.agent.asked.map(\.text) == ["when is the quiz", "send it to Anna"]))
        #expect(r.ear.follows.last == 0 && w.followUntil == 0 && w.tw.text == "" && r.agent.stopped.isEmpty)
        #expect(w.mind.activity == .thinking)  // not left listening
        if chat {
            #expect(w.chatOpen && w.card.isHidden)
            #expect(w.transcript.turns.map(\.text) == ["when is the quiz", "Your quiz is on Friday.", "send it to Anna", ""])
        } else {
            #expect(w.card.heardShown == "send it to Anna" && w.card.followUpShown)
        }
        r.agent.gate.signal()
        #expect(await pump(!w.busy))
        #expect(await r.run(until: w.tw.text == "Sent." && w.typed))
    }

    @Test func aHandsFreeSentenceDuringARunStopsItAndIsAskedAfterIt() async {
        let r = Rig([delta("long"), .wait, .event(.runEnded(status: "cancelled"))])
        defer { r.close() }
        r.window.ask("first")
        #expect(await pump(r.window.mind.activity == .talking))
        r.ear.handsFree = true
        r.ear.onText("second")
        #expect(await pump(r.agent.stopped.first == "run_1"))
        r.agent.script = [completed("ok")]
        r.agent.gate.signal()
        #expect(await pump(r.agent.asked.map(\.text) == ["first", "second"]))
        #expect(await pump(!r.window.busy))
        #expect(shown(r) == "ok" && r.window.mind.activity != .listening)
    }

    /// The flag belongs to its text: the listener's thread can deliver again before the hop to the main thread has run. Only a
    /// hands-free text does the wake, which is what clears a microphone note.
    @Test func aLaterDeliveryDoesNotChangeWhetherATextWasHandsFree() async {
        let r = Rig([completed("ok")])
        defer { r.close() }
        r.window.noted = true
        r.ear.handsFree = false
        r.ear.onText("with the key")
        r.ear.handsFree = true  // the next delivery comes before the main thread has run
        #expect(await pump(!r.agent.asked.isEmpty && !r.window.busy))
        #expect(r.window.noted)  // no wake for the first text
        r.ear.onText("without the key")
        #expect(await pump(r.agent.asked.count == 2))
        #expect(!r.window.noted)
    }

    /// The pet starts for its corner at once: the resting tick can be half a second away.
    @Test func aCallMovesThePetAtOnceNotAtTheNextRestingTick() {
        let r = Rig()
        defer { r.close() }
        #expect(r.window.roamer.mode != .come)
        r.window.onEvent(.listening(true))
        #expect(r.window.roamer.mode == .come)
    }

    @Test func theResultsOfTheListenerThreadHopToTheMainThread() async {
        let r = Rig([completed("ok")])
        defer { r.close() }
        let done = Flag()
        let ear = r.ear
        Thread.detached {
            ear.onWake()  // the listener's thread
            ear.onText("hello robo")
            done.value = true
        }
        #expect(await pump(done.value && !r.agent.asked.isEmpty))
        #expect(r.agent.asked[0].text == "hello robo")
    }

    @Test func theAgentLightFollowsTheHealthPoller() async {
        let r = Rig(health: "http://127.0.0.1:8765")
        defer { r.close() }
        let p = r.pollers[0]
        #expect(p.url == "http://127.0.0.1:8765" && p.started == 1 && r.window.link == .unknown)
        for (state, led) in [(HealthState.ok, LedState.ok), (.warn, .warn), (.bad, .bad), (.ok, .ok)] {
            p.onState(state)  // what the poller's thread does through the bridge
            #expect(await pump(r.window.link == led))
        }
    }
}

extension Thread {
    /// A thread that runs `block` and ends.
    static func detached(_ block: @escaping @Sendable () -> Void) {
        let t = Thread(block: block)
        t.start()
    }
}

// MARK: - robo chat

@MainActor @Suite(.serialized) struct ChatTests {
    private func chat(_ agent: FakeAgent, lines: [String?]) async -> (code: Int32, out: String) {
        var input = lines[...]
        var out = ""
        let code = await runChat(agent, session: "robo-chat-test", readLine: { input.popFirst() ?? nil },
                                 write: { out += $0 }, handleCtrlC: false)
        return (code, out)
    }

    @Test func theTranscriptShowsFeelingsAndText() async {
        let h = FakeAgent([.event(.feeling("happy")), delta("Hello"), delta(" there"), completed("Hello there")])
        let (code, out) = await chat(h, lines: ["hi", "", "  ", nil])
        #expect(code == 0)
        #expect(out == "you> [happy] Hello there\nyou> you> you> ")
        #expect(h.asked.map(\.text) == ["hi"] && h.asked[0].session == "robo-chat-test")
    }

    @Test func aFailedRunPrintsItsStatusAndError() async {
        let h = FakeAgent([.event(.runEnded(status: "failed", error: "boom"))])
        let (_, out) = await chat(h, lines: ["x", nil])
        #expect(out == "you> \n[failed] boom\nyou> ")
    }

    @Test func aBrainErrorPrintsAndTheLoopGoesOn() async {
        let h = FakeAgent(fail: BrainError("The agent is not running"))
        let (code, out) = await chat(h, lines: ["x", "y", nil])
        #expect(code == 0 && out == "you> [error] The agent is not running\nyou> [error] The agent is not running\nyou> ")
        #expect(h.asked.count == 2)
    }
}

// MARK: - starting up

@Suite struct StartTests {
    @Test func theDevSwitchesAreOffUnlessSet() {
        #expect(DevSwitches(environment: [:]) == DevSwitches(environment: ["ROBO_NO_VOICE": "0", "ROBO_AGENT_URL": ""]))
        let off = DevSwitches(environment: [:])
        #expect(!off.noVoice && !off.otherAgent && !off.chatDemo)
        let on = DevSwitches(environment: ["ROBO_NO_VOICE": "1", "ROBO_AGENT_URL": "http://127.0.0.1:9", "ROBO_CHAT_DEMO": "1"])
        #expect(on.noVoice && on.otherAgent && on.chatDemo)
        #expect(!DevSwitches(environment: ["ROBO_NO_VOICE": "1"]).otherAgent)  // each on its own
    }

    /// The app's client: no DeepSeek key = one clear line and nothing started; else the service is made sure of before the request.
    @Test func theKeeperSaysWhenTheKeyIsMissingAndStartsTheAgentBeforeAsking() async throws {
        final class Box: @unchecked Sendable { var launches = 0, up = false }
        let box = Box()
        let service = AgentService(command: ["uv"], environment: [:], log: URL(fileURLWithPath: "/dev/null"), healthy: { box.up },
                                   launch: { _, _, _ in box.launches += 1; box.up = true; return Process() }, sleep: { _ in })
        let fake = FakeAgent([.event(.runEnded(status: "completed", output: "hi"))])
        var hasKey = false
        let keeper = AgentKeeper(fake, service: service, hasKey: { hasKey })
        do {
            for try await _ in keeper.ask("hello", sessionId: "s", started: nil) {}
            Issue.record("expected the key error")
        } catch let e as BrainError {
            #expect(e.message == AgentHome.noKeyMessage && e.message.contains("robo key set deepseek"))
        }
        #expect(box.launches == 0 && fake.asked.isEmpty)
        hasKey = true
        var events: [Event] = []
        for try await e in keeper.ask("hello", sessionId: "s", started: nil) { events.append(e) }
        #expect(box.launches == 1 && fake.asked.map(\.text) == ["hello"] && events.count == 1)
        // ROBO_AGENT_URL: no service, the client itself (no key check: that agent is not ours)
        hasKey = false
        for try await _ in AgentKeeper(fake, service: nil, hasKey: { hasKey }).ask("again", sessionId: "s", started: nil) {}
        #expect(fake.asked.map(\.text) == ["hello", "again"])
    }

    @Test func theRealMachineReadsTheThemeFromTheConfigFolder() {
        #expect(Machine().themeFile == Themes.configPath())
    }
}
