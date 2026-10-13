// The reply typed letter by letter, and the themes (tests/test_chat_ui.py): see AppTests.swift for the helpers.
import AppKit
import Foundation
import Testing
import RoboCore
import RoboSystem
@testable import RoboUI

// MARK: - the typed reply
// Time here is the rig's frozen clock moved by `Rig.step` (33 ms at a time), so nothing depends on real speed.

@MainActor @Suite(.serialized) struct TypingTests {
    @Test func theReplyTypesAtTheThemeSpeedAndNeverRunsAheadOfHermes() async {
        let r = Rig([delta("Hello there, "), .wait, delta("this is a short reply."), completed(HELLO)], cps: 55)
        defer { r.close() }
        let w = r.win
        #expect(w.tw.pace.cps == 55)
        let begun = r.clock.now()
        w.ask("hi")
        var seen: [(text: String, k: Int, reply: String)] = []
        var talked = false, closedUnderTheReader = false
        #expect(await r.run(until: {
            seen.append((shown(r), w.tw.k, w.reply))
            talked = talked || w.face.talking
            closedUnderTheReader = closedUnderTheReader || w.closeAt != 0
            return w.tw.k >= "Hello there, ".count && !w.tw.pending
        }()))  // it caught up with what Hermes has sent so far
        // 13 characters at 55 per second plus the pause after the comma: a quarter to a half second
        let took = r.clock.now() - begun
        #expect(took > 0.2 && took < 0.6, "typing 13 characters took \(took) s")
        #expect(await r.run(until: !w.mind.talking && !w.face.talking))  // the mouth closed to wait
        r.hermes.gate.signal()
        #expect(await r.run(until: w.typed))
        #expect(!closedUnderTheReader)  // a reply is never closed under the reader
        #expect(Set(seen.map(\.text)).count >= 2)  // typed, not shown at once: more than one stage was on screen
        #expect(seen.allSatisfy { $0.k <= $0.reply.unicodeScalars.count })  // never past what Hermes sent
        #expect(talked && shown(r) == HELLO)  // the mouth moved while letters appeared
        #expect(await r.run(until: !w.face.talking))
        #expect(w.closeAt == w.typedAt + RoboWindow.closeAfter)
    }

    @Test func theFirstLettersShowAtOnce() async {
        let r = Rig(cps: 55)
        defer { r.close() }
        r.window.feed("Hello wonderful world")  // one step: only the first letters are due
        #expect(r.window.tw.k > 0 && r.window.tw.k < "Hello".count)
        #expect(r.window.tw.view().hidden > 0)  // the rest of the word is laid out, painted transparent
        #expect(r.window.revealer != nil)
    }

    @Test func aClickOnTheReplyShowsTheRest() async {
        let r = Rig([delta(LONG), completed(LONG)], cps: 55)
        defer { r.close() }
        let w = r.win
        w.ask("go")
        #expect(await r.run(until: w.tw.k > 5))
        #expect(w.tw.pending && w.closeAt == 0)
        w.card.onReplyClick?()
        #expect(w.tw.skipped && !w.tw.pending)
        #expect(await r.run(until: w.typed, steps: 50))  // no waiting for the typing: only for Hermes' last event
        #expect(shown(r) == LONG && w.revealer == nil)
        #expect(w.closeAt == w.typedAt + RoboWindow.closeAfter)
    }

    @Test func escapeShowsTheRestFirstAndTheNextOneCloses() async {
        let r = Rig([delta(LONG), completed(LONG)], cps: 55)
        defer { r.close() }
        let w = r.win
        w.ask("go")
        #expect(await r.run(until: !w.busy && w.tw.k > 5))  // Hermes is done, the letters are not
        #expect(w.tw.pending)
        w.escape()
        #expect(shown(r) == LONG && !w.card.isHidden && w.typed)
        w.escape()
        #expect(w.card.isHidden && w.closeAt == 0)
    }

    @Test func escapeWhileHermesRunsStopsTheRunAndLeavesTheTyping() async {
        let r = Rig([delta(LONG), .wait, .event(.runEnded(status: "cancelled"))], cps: 55)
        defer { r.close() }
        r.window.ask("go")
        #expect(await r.run(until: r.window.tw.k > 5))
        r.window.escape()
        #expect(await r.run(until: r.hermes.stopped == ["run_1"]))
        #expect(!r.window.tw.skipped)
        r.hermes.gate.signal()
        #expect(await r.run(until: !r.window.busy))
    }

    @Test func skippingWhileHermesStillStreamsShowsWhatArrivesAtOnce() async {
        let r = Rig([delta(String(LONG.prefix(200))), .wait, delta(String(LONG.dropFirst(200))), .wait, completed(LONG)], cps: 55)
        defer { r.close() }
        let w = r.win
        w.ask("go")
        #expect(await r.run(until: w.tw.k > 5))
        w.skip()
        #expect(w.tw.skipped && !w.typed)  // Hermes has not finished
        #expect(shown(r) == String(LONG.prefix(200)))
        r.hermes.gate.signal()
        #expect(await r.run(until: shown(r).count == LONG.count))
        r.hermes.gate.signal()
        #expect(await r.run(until: w.typed))
    }

    @Test func aFinalTextThatDiffersFromTheStreamIsRetypedFromTheFirstDifference() async {
        let r = Rig([delta("Helo wor"), completed("Hello world, all done.")], cps: 400)
        defer { r.close() }
        r.window.ask("go")
        #expect(await r.run(until: r.window.typed))
        #expect(shown(r) == "Hello world, all done." && r.window.tw.text == "Hello world, all done.")  // not a garbled mix
    }

    @Test func aLocalMessageIsTypedAndClosesEightSecondsAfterTheLastLetter() async {
        let r = Rig(cps: 55)
        defer { r.close() }
        let w = r.win
        w.say("Sorry, I didn't catch that.")
        #expect(w.tw.pending && w.closeAt == 0 && w.card.heardShown == "")
        #expect(await r.run(until: w.typed))
        #expect(shown(r) == "Sorry, I didn't catch that.")
        #expect(w.closeAt == w.typedAt + 8)
    }

    @Test func aNewQuestionMidTypingClearsEverythingOfTheOldReply() async {
        let r = Rig([delta(LONG), completed(LONG)], cps: 55)
        defer { r.close() }
        let w = r.win
        r.hermes.onAsk = { write([r.vault.appendingPathComponent("Notes/A note.md"): "x"]) }
        w.ask("first")
        #expect(await r.run(until: !w.busy && w.tw.k > 5))
        #expect(w.tw.pending && !w.card.footerShown.isEmpty && w.card.footer.isHidden)
        r.hermes.onAsk = nil
        r.hermes.script = [.event(.toolStarted("web_search")), .wait, completed("ok")]
        w.ask("second")  // asked while the first answer is still on screen
        #expect(w.tw.text == "" && w.revealer == nil && w.closeAt == 0)
        #expect(w.card.footerShown == "" && w.card.footer.isHidden)
        #expect(w.card.heardShown == "second" && w.card.followUpShown)  // a follow-up
        #expect(!w.card.caretShown.show)
        r.hermes.gate.signal()
        #expect(await r.run(until: !w.busy))
    }

    @Test func speakingOverATypingAnswerClearsIt() async {
        let r = Rig([delta(LONG), completed(LONG)], cps: 55)
        defer { r.close() }
        let w = r.win
        w.ask("go")
        #expect(await r.run(until: !w.busy && w.tw.k > 5))
        r.ear.onWake()
        #expect(await r.run(until: w.mind.activity == .listening))
        #expect(w.tw.text == "" && w.revealer == nil && w.card.heardShown == "")
    }

    @Test func theFooterShowsWhenTheTypingIsDoneAndIsNotPartOfTheMarkdown() async {
        let reply = "It is **in Obsidian** now."
        let r = Rig([delta(reply), completed(reply)], cps: 40)
        defer { r.close() }
        r.hermes.onAsk = { write([r.vault.appendingPathComponent("Drafts/Email to Prof Lee.md"): "Hi"]) }
        let w = r.win
        w.ask("write me an email")
        #expect(await r.run(until: !w.busy))
        #expect(w.tw.pending && !w.typed && w.card.footer.isHidden)  // still typing: the footer is not up
        #expect(w.card.footerShown == "📓 In Obsidian: Email to Prof Lee")
        #expect(await r.run(until: w.typed))
        #expect(!w.card.footer.isHidden)
        #expect(shown(r) == reply && !w.tw.text.contains("📓"))
    }

    @Test func aLocalNoteDuringARunLeavesTheFooterAndTheAutoCloseWorking() async {
        let reply = "It is in Obsidian now."
        let r = Rig([delta("It is "), .wait, delta("in Obsidian now."), completed(reply)], cps: 200)
        defer { r.close() }
        r.hermes.onAsk = { write([r.vault.appendingPathComponent("Drafts/Email to Prof Lee.md"): "Hi"]) }
        let w = r.win
        w.ask("write me an email")
        #expect(await r.run(until: w.tw.k > 2))
        r.ear.onNote("The microphone stopped.")  // a local note while Hermes is still streaming
        #expect(await r.run(until: w.tw.text == "The microphone stopped."))
        #expect(await r.run(until: !w.tw.pending))
        #expect(w.busy && w.closeAt == 0)
        r.hermes.gate.signal()
        #expect(await r.run(until: !w.busy && w.tw.text == reply && !w.tw.pending))
        #expect(await r.run(until: w.typed))
        #expect(shown(r) == reply && w.card.footerShown == "📓 In Obsidian: Email to Prof Lee" && !w.card.footer.isHidden)
        #expect(w.closeAt == w.typedAt + RoboWindow.closeAfter)  // it closes by itself
    }

    @Test func theCaretShowsWhileTypingBlinksWhenWaitingAndGoesAMomentAfterTheEnd() async {
        let r = Rig([delta("Friday has the **lab"), .wait, delta(" report** due."),
                     completed("Friday has the **lab report** due.")], cps: 55)
        defer { r.close() }
        let w = r.win
        w.ask("go")
        #expect(await r.run(until: w.tw.k > 4 && w.card.caretShown.show))
        #expect(await r.run(until: !w.tw.pending))  // caught up: waiting for Hermes
        var seen = Set<Bool>()
        #expect(await r.run(until: { seen.insert(w.card.caretShown.on); return seen.count == 2 }(), steps: 120))  // it blinks
        r.hermes.gate.signal()
        #expect(await r.run(until: w.typed))
        #expect(w.card.caretShown.show)
        r.clock.advance(RoboWindow.caretS + 0.1)  // a while after the last letter
        w.refresh()
        #expect(!w.card.caretShown.show)
    }

    @Test func instantTypingHasNoCaretAndNoTimer() async {
        let r = Rig([delta(LONG), completed(LONG)], cps: 0)
        defer { r.close() }
        r.window.ask("go")
        #expect(await r.run(until: r.window.typed))
        #expect(shown(r) == LONG && !r.window.card.caretShown.show && r.window.revealer == nil)
    }

    @Test func anErrorKeepsItsSadFaceWhileItsTextTypes() async {
        let err = "Hermes is not running (connection refused); start it."
        let r = Rig([.event(.runEnded(status: "failed", error: err))], cps: 55)
        defer { r.close() }
        let w = r.win
        w.ask("go")
        #expect(await r.run(until: w.tw.k > 3))
        #expect(w.mind.activity == .error && w.face.activity == .error)  // not "talking"
        #expect(await r.run(until: w.typed))
        #expect(shown(r) == err)
    }

    @Test func theFaceKeepsTheTalkingPoseWhileLettersAreStillDue() async {
        let r = Rig([delta(LONG), completed(LONG)], cps: 55)
        defer { r.close() }
        let w = r.win
        w.ask("go")
        #expect(await r.run(until: !w.busy && w.tw.pending))
        #expect(w.mind.activity == .idle && w.face.activity == .talking)  // runEnded made it idle
        #expect(await r.run(until: w.typed))
        #expect(await r.run(until: w.face.activity == .idle))
    }

    @Test func aCpsOfZeroFromAThemeSwitchFinishesAReplyThatIsBeingTyped() async {
        let r = Rig([delta(LONG), completed(LONG)], cps: 55)
        defer { r.close() }
        let w = r.win
        w.ask("go")
        #expect(await r.run(until: !w.busy && w.tw.k > 5))
        try? "{\"tokens\": {\"cps\": 0}}".write(to: r.theme, atomically: true, encoding: .utf8)
        w.applyTheme(Themes.load(path: r.theme))
        #expect(await r.run(until: w.typed, steps: 50))
        #expect(shown(r) == LONG)
        try? "{\"tokens\": {\"cps\": 55}}".write(to: r.theme, atomically: true, encoding: .utf8)
        w.applyTheme(Themes.load(path: r.theme))  // and a speed again for the next one
        #expect(w.tw.pace.cps == 55)
    }
}

// MARK: - themes

@MainActor @Suite(.serialized) struct ThemeTests {
    private func saved(_ r: Rig) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: r.theme))) as? [String: Any] ?? [:]
    }

    @Test func aSwatchSwitchesTheLookAtOnceAndIsRememberedWithTheOtherSettings() async {
        let r = Rig(cps: 0, tokens: ", \"bot_name\": \"PIXEL\"")
        defer { r.close() }
        let w = r.win
        let old = w.theme
        w.card.onPickTheme?("matrix")
        let t = Themes.matrix
        #expect(w.theme.key == "matrix" && w.theme.botName == "PIXEL")  // tokens kept
        #expect(w.tw.pace.cps == 0)  // and so is the typing speed from them
        #expect(w.theme != old && w.theme.text == t.text)
        #expect(w.card.theme.key == "matrix")  // the card was restyled
        let bg = Themes.rgba(t.faceBg.centre)
        #expect(w.face.hueFn != nil && w.face.bg?.0 == bg)
        let file = saved(r)
        #expect(file["theme"] as? String == "matrix" && (file["tokens"] as? [String: Any])?["bot_name"] as? String == "PIXEL")
        #expect(Themes.load(path: r.theme).key == "matrix")
        #expect(w.themeStamp == Themes.stamp(path: r.theme))
        w.typeText()
        #expect(r.typers.count == 1)  // the Type window takes the theme too (TypePanel tests)
    }

    @Test func aThemeThatCannotBeSavedStillAppliesForThisRun() async {
        let r = Rig()
        defer { r.close() }
        let blocked = r.dir.appendingPathComponent("file")
        try? "not a folder".write(to: blocked, atomically: true, encoding: .utf8)
        r.window.machine.themeFile = blocked.appendingPathComponent("theme.json")
        r.window.card.onPickTheme?("amber")
        #expect(r.window.theme.key == "amber")
        #expect(!FileManager.default.fileExists(atPath: r.window.machine.themeFile.path))
    }

    @Test func aThemeJsonEditedByHandShowsWhenTheMenuOpens() async {
        let r = Rig()
        defer { r.close() }
        let w = r.win
        #expect(w.theme.key == "cyan")
        w.showMenu()
        #expect(w.theme.key == "cyan")  // nothing changed: nothing re-read
        try? await Task.sleep(for: .milliseconds(20))
        try? "{\"theme\": \"aurora\", \"tokens\": {\"cps\": 0, \"hue\": 300}}".write(to: r.theme, atomically: true, encoding: .utf8)
        w.showMenu()
        #expect(w.theme.key == "aurora" && w.theme.hue == 300)
    }

    @Test func theFaceTakesTheNewThemesHuesAtOnceButSweepsToThem() async {
        let r = Rig()
        defer { r.close() }
        let w = r.win
        #expect(w.face.goal.hue == Themes.cyan.hue + 0)  // snapped at start-up
        w.card.onPickTheme?("matrix")
        #expect(w.face.goal.hue == 128)
        #expect(w.face.params.hue == 188)  // the sweep to it takes about 0.3 s
    }

    @Test func theMenuOpensTheCardForEightSeconds() async {
        let r = Rig()
        defer { r.close() }
        r.window.card.onPickTheme?("daylight")
        #expect(r.window.closeAfter == 8 && !r.window.card.isHidden)
    }
}

