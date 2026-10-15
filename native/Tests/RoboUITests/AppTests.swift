// The conversation: port of the behaviour cases of tests/test_app.py and tests/test_chat_ui.py, with a
// fake Hermes, a fake ear and a temp home (the rig is in TestRig.swift).
//
// Not ported, because there is nothing left to test or the card (CardView, its own tests) owns it: the
// Qt style-sheet, QTextDocument, scroll-bar, widget-geometry and pixel-diff checks; the docked window; the
// compositor drag (startSystemMove); the QShortcut; WA_MacAlwaysShowToolWindow (the panel tests cover the
// stay-on-top behaviour); TypingDots.offsets; `open_file` choosing xdg-open or open.
import AppKit
import Foundation
import Testing
import RoboCore
import RoboSystem
@testable import RoboUI

let HELLO = "Hello there, this is a short reply."
let LONG = (0..<45).map { "word\($0)" }.joined(separator: " ")  // about 250 characters: seconds to type
func completed(_ text: String) -> FakeHermes.Step { .event(.runEnded(status: "completed", output: text)) }
func delta(_ text: String) -> FakeHermes.Step { .event(.delta(text)) }

/// What the window shows of the reply now: the typewriter's view (Markdown, as the card gets it).
@MainActor func shown(_ r: Rig) -> String { r.window.tw.view().markdown }

@MainActor func write(_ files: [URL: String], bump: Bool = true) {
    let now = Date().timeIntervalSince1970
    for (i, (url, body)) in files.sorted(by: { $0.key.path < $1.key.path }).enumerated() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? body.write(to: url, atomically: true, encoding: .utf8)
        if bump { try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now + Double(i))], ofItemAtPath: url.path) }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var value: Bool { get { lock.withLock { on } } set { lock.withLock { on = newValue } } }
}

// MARK: - asking Hermes

@MainActor @Suite(.serialized) struct AskTests {
    @Test func theReplyStreamsWithoutTagsAndReturnsToIdle() async {
        let r = Rig([.event(.feeling("happy")), delta("Hel"), delta("lo **you**"), completed("Hello **you**")])
        defer { r.close() }
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        #expect(r.hermes.asked.map(\.text) == ["hi"] && r.hermes.asked[0].session == r.window.sessionID)
        #expect(shown(r) == "Hello **you**" && !shown(r).contains("[["))
        #expect(r.window.mind.activity == .idle && r.window.mind.emotion == "happy")
    }

    @Test func aBrainErrorShowsItsMessageAndASadFace() async {
        let r = Rig(fail: BrainError("Hermes is not running"))
        defer { r.close() }
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        #expect(shown(r) == "Hermes is not running")  // no generic prefix
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
        let r = Rig(fail: BrainError("Hermes is not running"), health: "http://127.0.0.1:9")
        defer { r.close() }
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        #expect(r.pollers[0].poked == 1)
        let quiet = Rig()  // no gateway url: no poller at all
        defer { quiet.close() }
        #expect(quiet.window.poller == nil && quiet.pollers.isEmpty)
    }

    @Test func theToolLabelShowsWhileWorkingAndAQuestionDuringARunWaitsForIt() async {
        let r = Rig([.event(.toolStarted("web_search")), .wait, completed("ok")])
        defer { r.close() }
        r.window.ask("news?")
        #expect(await pump(r.window.mind.activity == .working))
        #expect(await pump(r.window.card.statusShown.contains("searching")))
        r.window.ask("second while busy")  // one run at a time: it is asked when this one ends
        r.hermes.gate.signal()
        #expect(await pump(r.hermes.asked.count == 2))
        #expect(r.hermes.asked.map(\.text) == ["news?", "second while busy"])
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    @Test func escapeStopsTheRun() async {
        let r = Rig([delta("long"), .wait, .event(.runEnded(status: "cancelled"))])
        defer { r.close() }
        r.window.ask("go")
        #expect(await pump(r.window.mind.activity == .talking))
        r.window.stop()
        #expect(await pump(r.hermes.stopped == ["run_1"]))
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    @Test(arguments: [("once", ApprovalChoice.once), ("deny", .deny)])
    func theApprovalBar(_ button: String, _ choice: ApprovalChoice) async {
        let r = Rig([.event(.approvalNeeded("open a page")), .wait, completed("ok")])
        defer { r.close() }
        r.window.ask("go")
        #expect(await pump(r.window.card.approvalShown != nil))
        #expect(r.window.card.approvalShown == "open a page")
        r.window.card.onApprove?(button)  // Allow, or Deny
        #expect(await pump(r.hermes.approved.map(\.choice) == [choice]))
        #expect(r.hermes.approved[0].run == "run_1" && r.window.card.approvalShown == nil)
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    @Test func aHugeApprovalIsShortenedSoTheButtonsStayOnScreen() async {
        let r = Rig([.event(.approvalNeeded("run: " + String(repeating: "x", count: 5000))), .wait,
                     .event(.runEnded(status: "cancelled"))])
        defer { r.close() }
        r.window.ask("go")
        #expect(await pump(r.window.card.approvalShown != nil))
        #expect(r.window.card.approvalShown!.unicodeScalars.count == RoboWindow.approvalMax && r.window.card.approvalShown!.hasSuffix("…"))
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    @Test func desktopControlNeedsNoPromptButIrreversibleStepsDo() async {
        let r = Rig([.event(.approvalNeeded("Allow computer_use to perform `click`?", desktop: true)),
                     .event(.approvalNeeded("Allow computer_use to perform `type`?", desktop: true)),
                     .event(.approvalNeeded("recursive delete: rm -rf ~/x")), .wait, completed("ok")])
        defer { r.close() }
        r.window.ask("open the calculator and compute 12*7")
        #expect(await pump(r.window.card.approvalShown != nil))  // only the delete asks
        #expect(await pump(r.hermes.approved.count == 2))
        #expect(r.hermes.approved.map(\.choice) == [.session, .session] && r.hermes.approved.allSatisfy { $0.run == "run_1" })
        #expect(r.window.card.approvalShown?.contains("rm -rf") == true)
        r.window.card.onApprove?("once")
        #expect(await pump(r.hermes.approved.last?.choice == .once))
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    @Test func anApprovalGetsItsOwnRoomInTheCard() async {
        let r = Rig()
        defer { r.close() }
        r.window.roamer.hold(now: r.clock.now(), pos: Vec(600, 400))
        r.window.move(to: r.window.roamer.pos)
        r.window.busy = true
        r.window.open()
        r.window.onEvent(.delta("**Today**\n- a\n- b\n- c"))
        let before = r.frame.height
        r.window.onEvent(.approvalNeeded("Robo wants to run: rm x"))
        #expect(r.frame.height > before)  // the window grew, nothing squeezed
        r.window.approve(.deny)
        #expect(r.frame.height == before)
    }

    // MARK: stopping

    @Test func stopBeforeTheRunExistsStopsItOnceStarted() async {
        let r = Rig([.event(.runEnded(status: "cancelled"))])
        r.hermes.beforeStart = Gate()
        defer { r.close() }
        r.window.ask("go")
        #expect(await pump(!r.hermes.asked.isEmpty))
        r.window.stop()  // no run id yet
        r.hermes.beforeStart?.signal()
        #expect(await pump(!r.window.busy))
        #expect(await pump(r.hermes.stopped == ["run_1"]))
    }

    @Test func stopWhileWaitingForTheNetworkNeverStartsARun() async {
        let online = Flag()
        let r = Rig([completed("digest")], digestDue: true, network: { online.value })
        defer { r.close() }
        #expect(await pump(r.window.busy))  // the start-up digest waits for the network
        r.window.stop()
        online.value = true
        #expect(await pump(!r.window.busy, timeout: 8))  // the wait polls every 2 s
        #expect(r.hermes.asked.isEmpty && r.window.mind.activity == .idle)
    }

    @Test func closingMidRunStopsIt() async {
        let r = Rig([delta("x"), .wait, .event(.runEnded(status: "cancelled"))])
        defer { r.close() }
        r.window.ask("go")
        #expect(await pump(r.window.mind.activity == .talking))
        r.window.quit()
        #expect(await pump(r.terminated))
        #expect(r.hermes.stopped.first == "run_1")
        r.hermes.gate.signal()
    }

    // MARK: sessions and the digest

    @Test func theSessionFollowsTheDate() async {
        var d = Rig.day
        let r = Rig([completed("ok")], today: { d })
        defer { r.close() }
        r.window.ask("a")
        #expect(await pump(!r.window.busy))
        d = d.adding(days: 1)
        r.window.ask("b")
        #expect(await pump(!r.window.busy))
        #expect(r.hermes.asked.map(\.session) == ["robo-2026-10-11", "robo-2026-10-12"])
    }

    @Test func theSessionCarriesThePersonaStamp() async {
        let r = Rig([completed("ok")], persona: "ab12cd34")
        defer { r.close() }
        r.window.ask("a")
        #expect(await pump(!r.window.busy))
        #expect(r.hermes.asked[0].session == "robo-2026-10-11-ab12cd34")
    }

    @Test func theDigestRunsOncePerDayAtStartAndOnWake() async {
        let r = Rig([completed("digest")], digestDue: true)
        defer { r.close() }
        #expect(await pump(r.hermes.asked.count == 1 && !r.window.busy))
        #expect(r.hermes.asked[0].text == RoboWindow.digestPrompt)
        #expect(!r.digest.due(Rig.day))
        r.window.maybeDigest()  // a later wake the same day: nothing
        _ = await pump(timeout: 0.3)
        #expect(r.hermes.asked.count == 1)
    }

    @Test func aFailedDigestStaysDue() async {
        let r = Rig([.event(.runEnded(status: "failed", error: "offline"))], digestDue: true)
        defer { r.close() }
        #expect(await pump(r.hermes.asked.count == 1 && !r.window.busy))
        #expect(r.digest.due(Rig.day))
    }

    @Test func aDigestAcrossMidnightCountsForTheDayItStarted() async {
        var d = Rig.day
        let r = Rig([.wait, completed("digest")], digestDue: true, today: { d })
        defer { r.close() }
        #expect(await pump(!r.hermes.asked.isEmpty))
        d = d.adding(days: 1)
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
        #expect(!r.digest.due(Rig.day) && r.digest.due(d))
    }

    // MARK: the quote

    @Test func theQuoteShowsWhatYouSaidAndHidesForTheDigest() async {
        let r = Rig([completed("ok")])
        defer { r.close() }
        r.window.ask("what's due?")
        #expect(await pump(!r.window.busy))
        #expect(r.window.card.heardShown == "what's due?" && !r.window.card.followUpShown)  // the first question is no follow-up
        r.window.ask(RoboWindow.digestPrompt)
        #expect(await pump(!r.window.busy))
        #expect(r.window.card.heardShown == "")
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

// MARK: - voice

@MainActor @Suite(.serialized) struct VoiceTests {
    @Test func theWakeWordListensThenTheHeardTextIsAsked() async {
        let r = Rig([completed("ok")])
        defer { r.close() }
        r.ear.onWake()
        #expect(await pump(r.window.mind.activity == .listening))
        #expect(!r.window.card.isHidden && r.window.card.statusShown == "listening")
        r.ear.onText("what's on my calendar today")
        #expect(await pump(!r.hermes.asked.isEmpty))
        #expect(r.hermes.asked[0].text == "what's on my calendar today")
        #expect(await pump(!r.window.busy))
    }

    @Test func nothingHeardSaysSoWithoutAsking() async {
        let r = Rig()
        defer { r.close() }
        r.ear.onWake()
        r.ear.onText("")
        #expect(await pump(r.window.tw.text.contains("didn't catch")))
        #expect(r.hermes.asked.isEmpty && r.window.mind.activity == .idle)
    }

    @Test func aWakeWhileAnsweringInterrupts() async {
        let r = Rig([delta("long answer"), .wait, .event(.runEnded(status: "cancelled"))])
        defer { r.close() }
        r.window.ask("tell me a story")
        #expect(await pump(r.window.mind.activity == .talking))
        r.ear.onWake()
        #expect(await pump(r.hermes.stopped == ["run_1"]))
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    @Test func speakingOverAnAnswerAsksTheNewQuestion() async {
        let r = Rig([delta("long"), .wait, .event(.runEnded(status: "cancelled"))])
        defer { r.close() }
        r.window.ask("tell me a story")
        #expect(await pump(r.window.mind.activity == .talking))
        r.ear.onWake()
        #expect(await pump(r.hermes.stopped == ["run_1"]))
        r.hermes.gate.signal()  // the old run ends while robo is still listening
        #expect(await pump(!r.window.busy))
        #expect(r.window.mind.activity == .listening && !r.window.tw.text.contains("cancelled"))
        r.hermes.script = [completed("ok")]
        r.ear.onText("what's due")
        #expect(await pump(r.hermes.asked.map(\.text) == ["tell me a story", "what's due"]))
    }

    @Test func aQuestionHeardDuringARunWaitsForIt() async {
        let r = Rig([delta("x"), .wait, completed("x")])
        defer { r.close() }
        r.window.ask("first")
        #expect(await pump(r.window.mind.activity == .talking))
        r.ear.onText("second")  // heard while the first still runs (its stop is on the way)
        r.hermes.script = [completed("second done")]
        r.hermes.gate.signal()
        #expect(await pump(r.hermes.asked.map(\.text) == ["first", "second"]))
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

    @Test func withoutAMicrophoneThereIsNoEarAndClickingTypes() async {
        let r = Rig(micOK: false)
        defer { r.close() }
        #expect(r.window.ear == nil)
        r.window.clicked()
        #expect(r.typers.count == 1)
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
        #expect(await pump(r.hermes.stopped == ["run_1"]) && r.ear.now == 1)
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    @Test func afterAnAnswerRoboListensForAReplyWithoutItsName() async {
        let r = Rig([completed("It's 3 pm.")])
        defer { r.close() }
        r.window.ask("what time is it")
        #expect(await pump(!r.window.busy))
        #expect(r.ear.follow == RoboWindow.followUpS)
    }

    @Test func aFailedAnswerOpensNoFollowUp() async {
        let r = Rig([.event(.runEnded(status: "failed", error: "offline"))])
        defer { r.close() }
        r.window.ask("x")
        #expect(await pump(!r.window.busy))
        #expect(r.ear.follow == 0)
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
        #expect(await pump(done.value && !r.hermes.asked.isEmpty))
        #expect(r.hermes.asked[0].text == "hello robo")
    }

    @Test func theHermesLightFollowsTheHealthPoller() async {
        let r = Rig(health: "http://127.0.0.1:8642/p/robo")
        defer { r.close() }
        let p = r.pollers[0]
        #expect(p.url == "http://127.0.0.1:8642/p/robo" && p.started == 1 && r.window.link == .unknown)
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
    private func chat(_ hermes: FakeHermes, lines: [String?]) async -> (code: Int32, out: String) {
        var input = lines[...]
        var out = ""
        let code = await runChat(hermes, session: "robo-chat-test", readLine: { input.popFirst() ?? nil },
                                 write: { out += $0 }, handleCtrlC: false)
        return (code, out)
    }

    @Test func theTranscriptShowsFeelingsTextAndTools() async {
        let h = FakeHermes([.event(.feeling("happy")), delta("Hello"), .event(.toolStarted("web_search")), delta(" there"),
                            completed("Hello there")])
        let (code, out) = await chat(h, lines: ["hi", "", "  ", nil])
        #expect(code == 0)
        #expect(out == "you> [happy] Hello\n  (web_search…)\n there\nyou> you> you> ")
        #expect(h.asked.map(\.text) == ["hi"] && h.asked[0].session == "robo-chat-test")
    }

    @Test func aFailedRunPrintsItsStatusAndError() async {
        let h = FakeHermes([.event(.runEnded(status: "failed", error: "boom"))])
        let (_, out) = await chat(h, lines: ["x", nil])
        #expect(out == "you> \n[failed] boom\nyou> ")
    }

    @Test func aBrainErrorPrintsAndTheLoopGoesOn() async {
        let h = FakeHermes(fail: BrainError("Hermes is not running"))
        let (code, out) = await chat(h, lines: ["x", "y", nil])
        #expect(code == 0 && out == "you> [error] Hermes is not running\nyou> [error] Hermes is not running\nyou> ")
        #expect(h.asked.count == 2)
    }
}

// MARK: - starting up

@Suite struct StartTests {
    @Test func theDevSwitchesAreOffUnlessSet() {
        #expect(DevSwitches(environment: [:]) == DevSwitches(environment: ["ROBO_NO_VOICE": "0", "ROBO_HERMES_URL": ""]))
        let off = DevSwitches(environment: [:])
        #expect(!off.noVoice && !off.noWatch && !off.otherGateway)
        let on = DevSwitches(environment: ["ROBO_NO_VOICE": "1", "ROBO_NO_WATCH": "1", "ROBO_HERMES_URL": "http://127.0.0.1:9"])
        #expect(on.noVoice && on.noWatch && on.otherGateway)
        #expect(DevSwitches(environment: ["ROBO_NO_VOICE": "1"]).noWatch == false)  // each on its own
    }

    /// The card's header chip is the model `robo setup` configures, not a copy of its name.
    @Test func theHeaderChipShowsTheModelSetupConfigured() {
        #expect(Setup.model.hasPrefix("claude-"))
        #expect(Themes.chipText(Themes.glass, configuredModel: Setup.model) == String(Setup.model.dropFirst(7)))
    }

    @Test func theMachineKeepsEverythingUnderTheHome() {
        let home = URL(fileURLWithPath: "/Users/jane")
        let m = Machine(home: home)
        #expect(m.outputDir.path == "/Users/jane/Robo")
        #expect(m.vaultDir == Vault.dir(home: home) && m.vaultDir.path == "/Users/jane/Documents/Robo")
        #expect(m.themeFile == Themes.configPath() && m.watchPausedFile.lastPathComponent == "watch.paused")
        #expect(m.watchPausedFile.deletingLastPathComponent() == ActivityLog.dataDir)
    }

    /// The digest date lives in the checkout's data folder, the file the Python build writes too.
    @Test func theDigestDateIsKeptInTheCheckoutsDataFolder() {
        let root = RoboApp.dataDir.deletingLastPathComponent()
        #expect(RoboApp.dataDir.lastPathComponent == "data")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("native/Package.swift").path))
    }
}
