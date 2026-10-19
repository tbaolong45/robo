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

    /// Hermes answers the OLDEST pending ask unless the answer names one: the card shows the oldest, the count of the others, and
    /// every click carries the id of the ask it answered.
    @Test func parallelAsksQueueInOrderAndEachClickCarriesItsOwnId() async {
        let r = Rig([.event(.approvalNeeded("send the mail to Anna", id: "A")), .event(.approvalNeeded("delete the note", id: "B")),
                     .event(.approvalNeeded("open a page", id: "C")), .wait, completed("ok")])
        defer { r.close() }
        r.window.ask("go")
        #expect(await pump(r.window.approvals.count == 3))
        #expect(r.window.card.approvalShown == "send the mail to Anna" && r.window.card.approval.label.text == "APPROVAL ▸ +2 MORE")
        r.window.card.onApprove?("once")
        #expect(await pump(r.hermes.approved.count == 1))
        #expect(r.window.card.approvalShown == "delete the note" && r.window.card.approval.label.text == "APPROVAL ▸ +1 MORE")
        r.window.card.onApprove?("deny")
        #expect(await pump(r.hermes.approved.count == 2))
        #expect(r.window.card.approvalShown == "open a page" && r.window.card.approval.label.text == "APPROVAL ▸")  // the last one: no count
        r.window.card.onApprove?("once")
        #expect(await pump(r.hermes.approved.count == 3))
        #expect(r.window.card.approvalShown == nil && r.window.approvals.isEmpty)
        #expect(r.hermes.approved.map(\.id) == ["A", "B", "C"] && r.hermes.approved.map(\.choice) == [.once, .deny, .once])
        #expect(r.hermes.approved.allSatisfy { $0.run == "run_1" })
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    @Test func aRunThatEndsClearsTheQueue() async {
        let r = Rig([.event(.approvalNeeded("send the mail to Anna", id: "A")), .event(.approvalNeeded("delete the note", id: "B")),
                     .wait, .event(.runEnded(status: "cancelled"))])
        defer { r.close() }
        r.window.ask("go")
        #expect(await pump(r.window.approvals.count == 2))
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
        #expect(r.window.approvals.isEmpty && r.window.card.approvalShown == nil)
        r.window.approve(.once)  // a click that arrives late answers nothing
        _ = await pump(timeout: 0.2)
        #expect(r.hermes.approved.isEmpty)
    }

    /// The old bug: the app's own "session" answer to a desktop step had no id, so with an ask already waiting Hermes took it for
    /// the OLDEST one, the user's, and approved it unseen.
    @Test func approvingADesktopStepNeverAnswersTheAskWaitingForTheUser() async {
        let r = Rig([.event(.approvalNeeded("Robo wants to click in Microsoft Outlook (computer_use).", id: "G")),
                     .event(.approvalNeeded("Allow computer_use to perform `click`?", desktop: true, id: "H")), .wait, completed("ok")])
        defer { r.close() }
        r.window.ask("answer the mail")
        #expect(await pump(r.hermes.approved.count == 1))
        #expect(r.hermes.approved[0].choice == .session && r.hermes.approved[0].id == "H")
        #expect(r.window.card.approvalShown == "Robo wants to click in Microsoft Outlook (computer_use).")  // robo-guard's ask waits for the click
        #expect(r.window.approvals.count == 1 && r.window.card.approval.label.text == "APPROVAL ▸")
        r.window.card.onApprove?("once")
        #expect(await pump(r.hermes.approved.count == 2))
        #expect(r.hermes.approved[1].choice == .once && r.hermes.approved[1].id == "G")
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    @Test(arguments: ["Microsoft Outlook", "Microsoft Teams"])
    func aGuardAskForOutlookOrTeamsShowsTheCardAndWaitsForTheClick(_ app: String) async {
        let r = Rig([.event(.approvalNeeded("Robo wants to type in \(app) (computer_use).", id: "G")), .wait, completed("ok")])
        defer { r.close() }
        r.window.ask("reply to Anna")
        #expect(await pump(r.window.card.approvalShown != nil))
        _ = await pump(timeout: 0.2)
        #expect(r.hermes.approved.isEmpty && r.window.card.approvalShown?.contains(app) == true)  // nothing is approved unseen
        r.window.card.onApprove?("deny")
        #expect(await pump(r.hermes.approved.count == 1))
        #expect(r.hermes.approved[0].choice == .deny && r.hermes.approved[0].id == "G")
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    /// Nobody is looking during the automatic digest (it only reads): every ask is denied at once, none waits on a card.
    @Test func theAutomaticDigestDeniesEveryAskAtOnce() async {
        let r = Rig([.event(.approvalNeeded("Robo wants to click \"Send\" on outlook.office.com.", id: "A")),
                     .event(.approvalNeeded("Allow computer_use to perform `click`?", desktop: true, id: "B")), .wait, completed("ok")],
                    digestDue: true)
        defer { r.close() }
        #expect(await pump(r.hermes.approved.count == 2))
        #expect(r.hermes.approved.map(\.choice) == [.deny, .deny] && r.hermes.approved.map(\.id) == ["A", "B"])
        #expect(r.hermes.approved.allSatisfy { $0.run == "run_1" })
        #expect(r.window.approvals.isEmpty && r.window.card.approvalShown == nil)  // no ask card, nothing to wait on
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    /// A digest from the menu is attended: its asks show the card.
    @Test func aDigestFromTheMenuAsks() async {
        let r = Rig([.event(.approvalNeeded("Robo wants to click \"Send\" on outlook.office.com.", id: "A")), .wait, completed("ok")])
        defer { r.close() }
        r.window.menu(.digest)
        #expect(await pump(r.window.card.approvalShown != nil))
        _ = await pump(timeout: 0.2)
        #expect(r.hermes.approved.isEmpty && !r.window.autoDigest)
        r.window.card.onApprove?("deny")
        #expect(await pump(r.hermes.approved.map(\.id) == ["A"]))
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
        #expect(await pump(!r.window.busy))  // the run's log line is written before the home is deleted
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

// MARK: - trust: receipts, usage log and cap, the working label

/// A line as robo-guard writes a receipt, stamped at `at` (wall seconds).
private func receipt(_ at: Double, tool: String = "browser_click", what: String = "Send", host: String = "outlook.office.com") -> String {
    #"{"ts": "\#(Usage.stamp(at))", "tool": "\#(tool)", "label_or_path": "\#(what)", "host": "\#(host)", "ok": true}"#
}
private func wallNow() -> Double { Date().timeIntervalSince1970 }

@MainActor @Suite(.serialized) struct TrustTests {
    private let sent = "✓ sent · outlook.office.com"

    // MARK: receipts in the footer

    @Test func theFooterShowsWhatTheGuardRecordedNextToTheNotes() async {
        let reply = "I sent the email."
        let r = Rig([delta(reply), completed(reply)])
        defer { r.close() }
        r.hermes.onAsk = {
            Usage.append(receipt(wallNow()), to: r.receipts)
            write([r.vault.appendingPathComponent("Drafts/Mail.md"): "Hi"])
        }
        r.window.ask("send it")
        #expect(await pump(!r.window.busy))
        #expect(r.window.card.footerShown == "📓 In Obsidian: Mail\n\(sent)")
        #expect(shown(r) == reply && !r.window.tw.text.contains("✓"))  // the footer is not part of the reply
    }

    @Test func aClaimWithoutARecordIsFlaggedAndNoClaimNeedsNoLine() async {
        let r = Rig([completed("I sent the email.")])
        defer { r.close() }
        r.window.ask("send it")
        #expect(await pump(!r.window.busy))
        #expect(r.window.card.footerShown == "⚠ unverified: sent (no send was recorded)")
        r.hermes.script = [completed("Here is the draft.")]
        r.window.ask("draft it")
        #expect(await pump(r.hermes.asked.count == 2 && !r.window.busy))
        #expect(r.window.card.footerShown == "")
    }

    @Test func receiptsFromBeforeThisRunAreNotCounted() async {
        let r = Rig([completed("I sent the email.")])
        defer { r.close() }
        Usage.append(receipt(wallNow() - 3600), to: r.receipts)  // an earlier mail, an hour ago
        r.window.ask("send it")
        #expect(await pump(!r.window.busy))
        #expect(r.window.card.footerShown == "⚠ unverified: sent (no send was recorded)")
    }

    @Test(arguments: ["failed", "cancelled"])
    func aRunThatDidNotCompleteStillShowsWhatHappened(status: String) async {
        let r = Rig([.event(.runEnded(status: status, error: status == "failed" ? "boom" : ""))])
        defer { r.close() }
        r.hermes.onAsk = { Usage.append(receipt(wallNow()), to: r.receipts) }
        r.window.ask("send it")
        #expect(await pump(!r.window.busy))
        #expect(r.window.card.footerShown == sent && shown(r) == (status == "failed" ? "boom" : "Run cancelled."))
        #expect(r.notes.isEmpty && r.files.isEmpty)  // nothing opened for a run that did not complete
    }

    // MARK: the usage log

    private func logged(_ r: Rig) throws -> [[String: Any]] {
        try String(contentsOf: r.usage, encoding: .utf8).split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    @Test func aFinishedRunIsLoggedWithItsTokensStepsSecondsAndStatus() async throws {
        let usage = UsageRecord(model: "claude-opus-4-5", input: 1200, output: 340, total: 1540, cacheRead: 9000, cacheWrite: 15)
        let r = Rig([.event(.toolStarted("web_search")), .event(.toolCompleted(tool: "web_search", error: false)),
                     .event(.toolStarted("web_extract")), .event(.toolCompleted(tool: "web_extract", error: false)), .wait,
                     .event(.usage(usage)), completed("ok")])
        defer { r.close() }
        r.window.machine.wall = { 1_792_393_402 }
        r.window.ask("news?")
        #expect(await pump(r.window.mind.activity == .thinking && r.window.card.statusShown.contains("reading")))
        r.clock.advance(12.5)
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
        let rows = try logged(r)
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row["ts"] as? String == Usage.stamp(1_792_393_402) && row["status"] as? String == "completed")
        #expect(row["steps"] as? Int == 2 && row["seconds"] as? Double == 12.5 && row["model"] as? String == "claude-opus-4-5")
        #expect(row["input"] as? Int == 1200 && row["output"] as? Int == 340 && row["total"] as? Int == 1540)
        #expect(row["cacheRead"] as? Int == 9000 && row["cacheWrite"] as? Int == 15)
        let mode = { (url: URL) in ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1 }
        #expect(mode(r.usage) == 0o600 && mode(r.usage.deletingLastPathComponent()) == 0o700)
    }

    @Test(arguments: ["failed", "cancelled"])
    func aRunThatDidNotCompleteIsLoggedWithoutTokens(status: String) async throws {
        let r = Rig([.event(.toolStarted("web_search")), .event(.runEnded(status: status))])
        defer { r.close() }
        r.window.ask("go")
        #expect(await pump(!r.window.busy))
        let rows = try logged(r)
        #expect(rows.count == 1 && rows[0]["status"] as? String == status && rows[0]["total"] as? Int == 0 && rows[0]["steps"] as? Int == 1)
    }

    @Test func aRunThatCouldNotStartLeavesNoLog() async {
        let r = Rig(fail: BrainError("Hermes is not running"))
        defer { r.close() }
        r.window.ask("hi")
        #expect(await pump(!r.window.busy))
        #expect(!FileManager.default.fileExists(atPath: r.usage.path))
    }

    // MARK: the daily cap

    private let message = "Today's token budget (100) is used up. Set ROBO_DAILY_TOKENS higher or wait for tomorrow."
    private let day = 1_792_393_402.0

    private func capped(_ r: Rig, cap: Int, used: Int, at: Double? = nil) {
        r.window.machine.wall = { [day] in day }
        r.window.machine.dailyTokens = cap
        Usage.append(Usage.line(UsageRecord(total: used), status: "completed", seconds: 1, steps: 0, wall: at ?? day), to: r.usage)
    }

    @Test func aReachedCapStartsNoRunAndSaysSo() async {
        let r = Rig([completed("ok")])
        defer { r.close() }
        capped(r, cap: 100, used: 100)
        r.window.ask("hi")
        #expect(shown(r) == message && !r.window.busy)
        #expect(r.window.card.reply.textView.string.contains("ROBO_DAILY_TOKENS higher"))  // the underscores are not Markdown
        #expect(!(await pump(!r.hermes.asked.isEmpty, timeout: 0.3)))  // Hermes was never asked
        #expect(r.window.mind.activity == .idle)
    }

    @Test(arguments: [(100, 99, 0.0), (0, 1_000_000, 0.0), (100, 5000, -3 * 86_400.0)])  // under, no cap, tokens of other days
    func anUnreachedOrAbsentCapLetsTheRunStart(cap: Int, used: Int, ago: Double) async {
        let r = Rig([completed("ok")])
        defer { r.close() }
        capped(r, cap: cap, used: used, at: day + ago)
        r.window.ask("hi")
        #expect(await pump(!r.window.busy && r.hermes.asked.count == 1))
        #expect(shown(r) == "ok")
    }

    @Test func theRunsOwnTokensCountTowardTheNextOne() async {
        let r = Rig([.event(.usage(UsageRecord(total: 100))), completed("ok")])
        defer { r.close() }
        capped(r, cap: 100, used: 0)
        r.window.ask("first")
        #expect(await pump(!r.window.busy && shown(r) == "ok"))
        r.window.ask("second")
        #expect(shown(r) == message && r.hermes.asked.map(\.text) == ["first"])
    }

    @Test func theCapReadsTheEnvironmentWhenTheMachineIsBuilt() {
        #expect(Machine(home: URL(fileURLWithPath: "/Users/jane")).dailyTokens == Usage.cap(ProcessInfo.processInfo.environment))
    }

    // MARK: the working label

    @Test func theLabelSaysOnItAtSendThenKeepsTheLastToolBetweenTools() async {
        let r = Rig([.event(.toolStarted("web_search")), .event(.toolCompleted(tool: "web_search", error: false)), .wait, completed("ok")])
        defer { r.close() }
        r.window.ask("news?")
        #expect(r.window.card.statusShown == "on it…" && r.window.card.dotsShown)
        #expect(await pump(r.window.mind.activity == .thinking && r.window.card.statusShown.contains("searching")))
        #expect(r.window.mind.label == "")  // the mind forgot the tool, the card did not
        r.window.tick()
        #expect(r.window.card.statusShown == "searching the web…")
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
        #expect(r.window.card.statusShown == "")
        r.hermes.script = [.wait, completed("again")]
        r.window.ask("again")  // a new request does not start with the old request's tool
        #expect(r.window.card.statusShown == "on it…")
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    @Test func after40SecondsItSaysHowLongEvery20() async {
        let r = Rig([.event(.toolStarted("web_search")), .wait, completed("ok")])
        defer { r.close() }
        r.window.ask("go")
        #expect(await pump(r.window.card.statusShown.contains("searching")))
        for (elapsed, want) in [(39.0, "searching the web…"), (1.0, "still working · 40 s"), (19.0, "still working · 40 s"),
                                (1.0, "still working · 60 s"), (35.0, "still working · 80 s"), (60.0, "still working · 140 s")] {
            r.clock.advance(elapsed)
            r.window.tick()
            #expect(r.window.card.statusShown == want)
        }
        r.hermes.gate.signal()
        #expect(await pump(!r.window.busy))
    }

    @Test func theWaitForAClickIsNotCountedAsWorking() async {
        let r = Rig([.event(.toolStarted("web_search")), .event(.approvalNeeded("send the mail")), .wait, completed("ok")])
        defer { r.close() }
        r.window.ask("go")
        #expect(await pump(r.window.card.approvalShown != nil))
        r.clock.advance(90)
        r.window.tick()
        #expect(r.window.card.statusShown == "")
        r.window.card.onApprove?("once")
        r.hermes.gate.signal()
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
        r.hermes.gate.signal()
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
        #expect(await r.run(until: !w.busy && w.tw.pending))  // Hermes is done, the letters are still coming
        #expect(!opened(r) && w.followUntil == 0 && w.followDue)  // typing does not eat the window
        #expect(w.card.header.mic.state != .hot)
        #expect(await r.run(until: w.typed))
        #expect(r.ear.follow == RoboWindow.followUpS && w.followUntil == w.typedAt + RoboWindow.followUpS)
        #expect(!w.followDue && w.card.header.mic.state == .hot)  // "LISTENING" while it waits for a reply
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

    @Test(arguments: [
        ("send it to Anna", true, false), ("gửi cho cô Lan", true, false), ("what is due tomorrow", true, true),
        ("send it to Anna", false, true),  // the key was held, or the face clicked: never filtered
    ])
    func aRequestChangingThingsNeedsTheKeyWhenItWasSaidWithoutOne(said: String, handsFree: Bool, asked: Bool) async {
        let r = Rig([completed("ok")])
        defer { r.close() }
        r.ear.onWake()
        r.ear.handsFree = handsFree  // the listener sets it before it delivers the text
        r.ear.onText(said)
        if asked {
            #expect(await pump(r.hermes.asked.map(\.text) == [said]))
        } else {
            #expect(await pump(r.window.tw.text == "That would change something, so hold Ctrl+Q and say it again."))
            _ = await pump(timeout: 0.2)
            #expect(r.hermes.asked.isEmpty && !r.window.busy && r.window.mind.activity == .idle)  // not listening, nothing sent
        }
    }

    @Test func speakingDuringAnApprovalStopsTheRunAndNeverApproves() async {
        let r = Rig([.event(.approvalNeeded("send the mail to Anna")), .wait, .event(.runEnded(status: "cancelled"))])
        defer { r.close() }
        r.window.ask("mail Anna")
        #expect(await pump(r.window.card.approvalShown != nil))
        r.ear.onWake()  // she starts to talk: the run is stopped, which is a deny
        #expect(await pump(r.hermes.stopped == ["run_1"]))
        r.ear.handsFree = true  // "yes, go ahead" in a window: not an approval, and a bare yes never acts without the key
        r.ear.onText("yes, go ahead")
        #expect(await pump(r.window.tw.text == "That would change something, so hold Ctrl+Q and say it again."))
        #expect(r.hermes.asked.map(\.text) == ["mail Anna"] && r.hermes.approved.isEmpty)
        r.ear.handsFree = false  // with the key held it is a new request (still not an approval)
        r.ear.onText("yes, go ahead")
        r.hermes.script = [completed("ok")]
        r.hermes.gate.signal()
        #expect(await pump(r.hermes.asked.map(\.text) == ["mail Anna", "yes, go ahead"]))
        #expect(await pump(!r.window.busy))
        #expect(r.hermes.approved.isEmpty && r.window.card.approvalShown == nil)
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
        // where robo-guard writes its receipts (`RECEIPTS` in hermes/plugins/robo-guard/__init__.py) and where the usage log goes
        #expect(m.receiptsFile == ActivityLog.dataDir.appendingPathComponent("receipts.jsonl"))
        #expect(m.usageFile == ActivityLog.dataDir.appendingPathComponent("usage.jsonl"))
    }

    /// The digest date lives in the checkout's data folder, the file the Python build writes too.
    @Test func theDigestDateIsKeptInTheCheckoutsDataFolder() {
        let root = RoboApp.dataDir.deletingLastPathComponent()
        #expect(RoboApp.dataDir.lastPathComponent == "data")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("native/Package.swift").path))
    }
}
