// The persona the service reads in place (agent/SOUL.md): the rules the app or the product depend on.
import Foundation
import Testing
@testable import RoboSystem

/// RoboCore's `emotions`; this target does not link RoboCore.
private let emotions = ["neutral", "happy", "curious", "proud", "concerned", "confused", "playful", "sad", "calm"]

private func soulText() throws -> String {
    try String(contentsOf: Setup.checkout.appendingPathComponent("agent/SOUL.md"), encoding: .utf8)
}

/// `" ".join(text.split())`: a rule wraps across lines in the Markdown.
private func oneLine(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

@Suite struct TemplatesTests {
    @Test func everyReplyStartsWithAFeelingTag() throws {
        #expect(try oneLine(soulText()).contains("Start EVERY reply with exactly one tag `[[feel:<emotion>]]`"))
    }

    @Test func soulListsExactlyTheAppEmotions() throws {
        let soul = try soulText()
        let line = try #require(soul.split(separator: "\n").first { $0.hasPrefix("neutral,") })
        #expect(line.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")) } == emotions)
        let tag = try NSRegularExpression(pattern: #"\[\[feel:(\w+)\]\]"#)
        let examples = tag.matches(in: soul, range: NSRange(soul.startIndex..., in: soul)).map { String(soul[Range($0.range(at: 1), in: soul)!]) }
        #expect(!examples.isEmpty && Set(examples).isSubset(of: Set(emotions)))
    }

    @Test func thePersonaSaysItHasNoTools() throws {
        let soul = try oneLine(soulText())
        for phrase in ["You are a chatbot with no tools", "never pretend you did something or looked something up"] {
            #expect(soul.contains(phrase), "SOUL.md lost '\(phrase)'")
        }
    }

    @Test func soulKeepsGradedWorkTheStudentsOwn() throws {
        let soul = try oneLine(soulText())
        for phrase in ["Graded work is the student's own", "never write, finish or fix an answer for it"] {
            #expect(soul.contains(phrase), "SOUL.md lost '\(phrase)'")
        }
    }

    @Test func thePersonaWritesMathsInLatexForTheChat() throws {
        let soul = try oneLine(soulText())
        for phrase in ["write formulas in LaTeX", "`$x^2$` inline and `$$ ... $$` on a line of their own", "the chat typesets them",
                       "Use `$` only for formulas, never for money or in code", "Put code in a fenced block with its language"] {
            #expect(soul.contains(phrase), "\(phrase)")
        }
    }
}
