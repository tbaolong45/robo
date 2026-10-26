// LaTeX taken out of a reply before it is parsed as Markdown: which spans are formulas and which stay text, and that the backslashes of a
// formula reach the typesetter untouched (pure).
import Foundation
import Testing
@testable import RoboCore

private func ph(_ n: Int) -> String { "\(Latex.open)\(n)\(Latex.close)" }

@Suite struct LatexExtractTests {
    @Test func anInlineFormulaBecomesAPlaceholderAndKeepsItsSource() {
        let r = Latex.extract("The loss is $L(w) = w^2$ here.")
        #expect(r.text == "The loss is \(ph(0)) here." && r.spans == [.init(source: "L(w) = w^2", display: false)])
    }

    @Test func displayFormulasInBothNotations() {
        let r = Latex.extract("Update:\n\n$$w_{t+1} = w_t - \\eta \\nabla L$$\n\nor \\[ \\sum_{i=1}^{n} x_i \\] done.")
        #expect(r.spans == [.init(source: "w_{t+1} = w_t - \\eta \\nabla L", display: true),
                            .init(source: "\\sum_{i=1}^{n} x_i", display: true)])
        #expect(r.text == "Update:\n\n\(ph(0))\n\nor \(ph(1)) done.")
    }

    @Test func theParenthesisNotationIsInline() {
        let r = Latex.extract("Take \\(x_i\\) and \\(y\\).")
        #expect(r.spans.map(\.source) == ["x_i", "y"] && r.spans.allSatisfy { !$0.display } && r.text == "Take \(ph(0)) and \(ph(1)).")
    }

    @Test func backslashesAndBracesReachTheTypesetterWhole() {
        let r = Latex.extract("$\\frac{\\partial L}{\\partial w}\\_\\{x\\}$")
        #expect(r.spans.map(\.source) == ["\\frac{\\partial L}{\\partial w}\\_\\{x\\}"])
    }

    @Test func aDisplayFormulaMaySpanLinesButNotABlankLine() {
        let two = Latex.extract("$$\na = b \\\\\nc = d\n$$")
        #expect(two.spans.map(\.source) == ["a = b \\\\\nc = d"])
        let blank = Latex.extract("$$ a\n\nb $$")
        #expect(blank.spans.isEmpty && blank.text == "$$ a\n\nb $$")
    }

    @Test(arguments: [
        "it costs $5 and $10 today", "$5 now, $6 later", "pay $ 5 or $ 6", "a $ b $ c", "$x", "x$", "an unclosed $y and more",
        "$$", "$$ $$ is empty?", "$ $", "100$ and 200$", "US$ and R$",
    ])
    func moneyAndLoneDollarsStayText(text: String) {
        let r = Latex.extract(text)
        #expect(r.spans.isEmpty && r.text == text, "\(text)")
    }

    @Test func theUsualMoneyRuleACharacterAfterTheClosingDollarMayNotBeADigit() {
        let r = Latex.extract("$a$5 and $b$.")
        #expect(r.spans.map(\.source) == ["b"])  // "$a$5" is not a formula, "$b$." is
    }

    @Test func codeIsNeverRead() {
        let inline = Latex.extract("Use `$x^2$` and ``a $y$ b`` here, but $z$ is math.")
        #expect(inline.spans.map(\.source) == ["z"] && inline.text.contains("`$x^2$`") && inline.text.contains("``a $y$ b``"))
        let fenced = Latex.extract("Look:\n```python\nprice = '$5'\nx = '$a$'\n```\nthen $b$.")
        #expect(fenced.spans.map(\.source) == ["b"] && fenced.text.contains("x = '$a$'"))
        let tilde = Latex.extract("~~~\n$a$\n~~~\n$b$")
        #expect(tilde.spans.map(\.source) == ["b"])
    }

    @Test func anEscapedDollarIsADollar() {
        let r = Latex.extract("\\$x$ and \\$5 or $y\\$ plain")
        #expect(r.spans.isEmpty && r.text == "\\$x$ and \\$5 or $y\\$ plain")
    }

    @Test func manyFormulasInARow() {
        let r = Latex.extract("$a$ $b$ $c$")
        #expect(r.text == "\(ph(0)) \(ph(1)) \(ph(2))" && r.spans.map(\.source) == ["a", "b", "c"])
    }

    @Test func aTextWithoutFormulasIsReturnedAsItWas() {
        for text in ["", "plain text", "a\\b and (c) and [d]", "# Heading\n\n- item `code`"] {
            let r = Latex.extract(text)
            #expect(r.text == text && r.spans.isEmpty)
        }
    }

    @Test func thereIsACapOnTheNumberAndTheLengthOfFormulas() {
        let many = (0..<80).map { "$x\($0)$" }.joined(separator: " ")
        #expect(Latex.extract(many).spans.count == Latex.maxSpans)
        let long = "$" + String(repeating: "a", count: Latex.maxLength + 10) + "$"
        #expect(Latex.extract(long).spans.isEmpty)
    }

    @Test func placeholdersAreFoundWhereTheyAre() {
        let r = Latex.extract("a $x$ b $$y$$ c")
        let found = Latex.placeholders(in: r.text)
        #expect(found.map(\.index) == [0, 1])
        let ns = r.text as NSString
        #expect(found.map { ns.substring(with: $0.range) } == [ph(0), ph(1)])
        #expect(Latex.placeholders(in: "no placeholders, \(Latex.open) alone, \(Latex.open)x\(Latex.close)").isEmpty)
    }
}
