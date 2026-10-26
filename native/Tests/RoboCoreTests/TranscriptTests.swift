// The conversation the chat window shows: turns in order, the one being written, local notices, the cap, and the reset when the agent's
// session changes (pure, in memory). (`#expect` cannot call a mutating method, so each result is taken first.)
import Testing
@testable import RoboCore

@Suite struct TranscriptTests {
    @Test func yourTurnIsCompleteAndRobosStartsOpen() {
        var t = Transcript()
        let a = t.append(.you, "hello")
        let b = t.append(.robo, "")
        #expect(a != b && t.turns.map(\.role) == [.you, .robo])
        #expect(t.turns[0].open == false && t.turns[1].open == true && t.writing)
    }

    @Test func theTurnBeingWrittenGrowsThenIsSealedWithItsFooterAndFailure() {
        var t = Transcript()
        t.append(.you, "what is due?")
        t.append(.robo, "")
        let grew = t.update("Two things")
        #expect(grew && t.turns[1].text == "Two things" && t.writing)
        let sealed = t.seal("Two things are due.", footer: ["📓 In Obsidian: Plan"], failed: false)
        #expect(sealed && !t.writing && t.turns[1].text == "Two things are due." && t.turns[1].footer == ["📓 In Obsidian: Plan"] && !t.turns[1].failed)
        // sealed: it can be neither updated nor sealed again
        let again = t.update("more"), twice = t.seal("again")
        #expect(!again && !twice && t.turns[1].text == "Two things are due.")
    }

    @Test func nothingIsWrittenWhenNoRoboTurnIsOpen() {
        var t = Transcript()
        let first = t.update("x"), second = t.seal("x")
        #expect(!first && !second && !t.writing && t.turns.isEmpty)
        t.append(.you, "hi")
        let third = t.update("x"), fourth = t.seal("x")
        #expect(!third && !fourth && t.turns.map(\.text) == ["hi"])
    }

    @Test func aFailedRunKeepsItsReasonAsAFailedTurn() {
        var t = Transcript()
        t.append(.robo, "")
        t.seal("Hermes can't be reached.", failed: true)
        #expect(t.turns[0].failed && t.turns[0].text == "Hermes can't be reached.")
    }

    @Test func aNoticeIsPlacedBeforeTheTurnBeingWrittenSoThatOneStaysLast() {
        var t = Transcript()
        t.append(.you, "question")
        t.append(.robo, "partial")
        t.note("Sorry, I didn't catch that.")
        #expect(t.turns.map(\.text) == ["question", "Sorry, I didn't catch that.", "partial"])
        #expect(t.turns[1].role == .robo && !t.turns[1].open && t.turns[2].open)
        let grew = t.update("partial answer")
        #expect(grew && t.turns[2].text == "partial answer")
        // with nothing being written it simply goes at the end
        t.seal("done")
        t.note("another")
        #expect(t.turns.last?.text == "another" && !t.writing)
    }

    @Test func anEmptyTurnIsDroppedButOneWithTextIsKept() {
        var t = Transcript()
        t.append(.you, "q")
        t.append(.robo, "")
        let dropped = t.dropEmptyLive()
        #expect(dropped && t.turns.count == 1 && !t.writing)
        t.append(.robo, "some words")
        let kept = t.dropEmptyLive()
        #expect(!kept && t.turns.count == 2)
        t.seal("some words")
        let sealed = t.dropEmptyLive()
        #expect(!sealed)  // sealed turns are never dropped
    }

    @Test func theOldestTurnsGoPastTheCapAndIdsStayUnique() {
        var t = Transcript()
        var ids = Set<Int>()
        for i in 0..<(Transcript.cap + 25) { ids.insert(t.append(i % 2 == 0 ? .you : .robo, "turn \(i)")) }
        #expect(t.turns.count == Transcript.cap && ids.count == Transcript.cap + 25)
        #expect(t.turns.first?.text == "turn 25" && t.turns.last?.text == "turn \(Transcript.cap + 24)")
        t.note("notice")
        #expect(t.turns.count == Transcript.cap)
    }

    @Test func anotherSessionStartsTheConversationAgain() {
        var t = Transcript()
        let first = t.reset(for: "robo-2026-10-23-abc")  // the first id: nothing to drop
        #expect(!first)
        t.append(.you, "hello")
        t.append(.robo, "hi")
        let same = t.reset(for: "robo-2026-10-23-abc")  // the same session: kept
        #expect(!same && t.turns.count == 2)
        let next = t.reset(for: "robo-2026-10-24-abc")
        #expect(next && t.turns.isEmpty && t.sessionID == "robo-2026-10-24-abc")
        let empty = t.reset(for: "robo-2026-10-25-abc")  // nothing to drop now, though the id changed
        #expect(!empty && t.sessionID == "robo-2026-10-25-abc")
    }
}
