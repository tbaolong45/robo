// LaTeX in a reply: typeset by SwiftMath into inline images that sit on the baseline and take the ink of the surface they are drawn on.
import AppKit
import Foundation
import Testing
import RoboCore
@testable import RoboUI

@MainActor private func attachments(_ s: NSAttributedString) -> [MathCell] {
    var cells: [MathCell] = []
    s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, _, _ in
        if let cell = (value as? NSTextAttachment)?.attachmentCell as? MathCell { cells.append(cell) }
    }
    return cells
}

@MainActor @Suite(.serialized) struct MathTests {
    init() { _ = NSApplication.shared }

    @Test func aFormulaIsTypesetWithASizeAndADescentAndTheFractionIsTallerThanALetter() throws {
        let x = try #require(Math.piece("x", fontSize: 14, display: false, maxWidth: 300))
        let frac = try #require(Math.piece("\\frac{a}{b}", fontSize: 14, display: false, maxWidth: 300))
        #expect(x.size.width > 3 && x.size.height > 5 && x.descent >= 0)
        #expect(frac.size.height > x.size.height && frac.descent > x.descent)  // the fraction reaches below the line
        #expect(x.onLight.size == x.size && x.onDark.size == x.size)
    }

    @Test func aFormulaThatIsNotLaTeXIsNil() {
        #expect(Math.piece("\\frac{a}{", fontSize: 14, display: false, maxWidth: 300) == nil)
        #expect(Math.piece("\\notacommand{x}", fontSize: 14, display: false, maxWidth: 300) == nil)
    }

    @Test func aWideFormulaIsSetSmallerToFitTheColumn() throws {
        let latex = "a_1 + a_2 + a_3 + a_4 + a_5 + a_6 + a_7 + a_8 + a_9 + a_{10} + a_{11} + a_{12} + a_{13} + a_{14}"
        let natural = try #require(Math.piece(latex, fontSize: 14, display: false, maxWidth: 10_000))
        let fitted = try #require(Math.piece(latex, fontSize: 14, display: false, maxWidth: natural.size.width * 0.75))
        #expect(fitted.size.width < natural.size.width && fitted.size.width >= natural.size.width * 0.6 - 2)
    }

    @Test func theTwoInksAreDifferentPicturesAndTheSurfaceDecidesWhichOneDraws() throws {
        let piece = try #require(Math.piece("E = mc^2", fontSize: 14, display: false, maxWidth: 300))
        func average(_ image: NSImage) -> Double {
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            var sum = 0.0, n = 0.0
            for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
                let c = rep.colorAt(x: x, y: y)!
                if c.alphaComponent > 0.5 { sum += Double(c.redComponent); n += 1 }
            } }
            return n > 0 ? sum / n : -1
        }
        #expect(average(piece.onLight) < 0.3 && average(piece.onDark) > 0.7)  // dark ink for a light glass, light ink for a dark one
        // the chat's formula follows the look of the view; the card's follows its ink level
        let chat = MathCell(piece: piece, ink: nil)
        let light = NSView(), dark = NSView()
        light.appearance = NSAppearance(named: .aqua)
        dark.appearance = NSAppearance(named: .darkAqua)
        #expect(chat.darkInk(in: light) && !chat.darkInk(in: dark))
        let card = MathCell(piece: piece, ink: 1)
        #expect(card.darkInk(in: dark) && !MathCell(piece: piece, ink: 0).darkInk(in: light))  // the level wins over the view's look
    }

    @Test func theBaselineOffsetIsTheDescent() throws {
        let piece = try #require(Math.piece("\\frac{a}{b}", fontSize: 14, display: false, maxWidth: 300))
        let cell = MathCell(piece: piece, ink: nil)
        #expect(cell.cellBaselineOffset().y == -piece.descent && cell.cellSize() == piece.size)
    }
}

@MainActor @Suite(.serialized) struct MathInTextTests {
    init() { _ = NSApplication.shared }
    private let theme = Themes.glass

    @Test func anInlineFormulaIsOneImageInTheSentenceAndTheRestIsText() {
        let s = Markdown.attributed("The loss is $L(w) = w^2$ and it falls.", theme: theme, ink: nil)
        #expect(attachments(s).count == 1)
        #expect(s.string.hasPrefix("The loss is ") && s.string.hasSuffix(" and it falls."))
        #expect(!s.string.contains("$") && !s.string.contains(String(Latex.open)))
        #expect(s.length == "The loss is ".utf16.count + 1 + " and it falls.".utf16.count)  // the formula is one character of the text
    }

    @Test func aFormulaIsTypesetFromItsSourceBeforeMarkdownCanSpoilIt() {
        // `\_`, `\{`, `\\` and `*` would be changed by a Markdown parser; here they reach the typesetter
        let s = Markdown.attributed("Here: $\\frac{\\partial L}{\\partial w_i} = x_i * \\{y\\}$ ok", theme: theme, ink: nil)
        #expect(attachments(s).count == 1 && !s.string.contains("partial"))
    }

    @Test func moneyAndCodeAreNotFormulas() {
        let money = Markdown.attributed("It costs $5 and $10, and `$x^2$` stays code.", theme: theme, ink: nil)
        #expect(attachments(money).isEmpty && money.string.contains("$5 and $10") && money.string.contains("$x^2$"))
    }

    @Test func aFormulaThatDoesNotTypesetStaysAsTheAuthorWroteIt() {
        let s = Markdown.attributed("Broken: $\\frac{a}{$ here, and $$\\bad{$$ too.", theme: theme, ink: nil)
        #expect(attachments(s).isEmpty && s.string.contains("$\\frac{a}{$") && s.string.contains("$$\\bad{$$"))
    }

    @Test func aDisplayFormulaOnItsOwnLineIsCentredAndLargerThanInlineText() throws {
        let s = Markdown.attributed("Update rule:\n\n$$w_{t+1} = w_t - \\eta \\nabla L$$\n\nThat is all.", theme: theme, ink: nil)
        let cells = attachments(s)
        #expect(cells.count == 1)
        let at = (s.string as NSString).range(of: "\u{FFFC}").location
        let style = s.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.alignment == .center)
        let inline = try #require(Math.piece("w_{t+1} = w_t - \\eta \\nabla L", fontSize: CGFloat(theme.textPx), display: false, maxWidth: 300))
        #expect(cells[0].piece.size.height > inline.size.height)
        // the paragraphs around it are not centred
        let before = s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(before?.alignment != .center)
    }

    @Test func severalFormulasKeepTheirOrder() {
        let s = Markdown.attributed("$a$, $b^2$ and $\\sqrt{c}$", theme: theme, ink: nil)
        #expect(attachments(s).count == 3)
        let widths = attachments(s).map(\.piece.size.width)
        #expect(widths[0] < widths[2])  // a is narrower than a square root of c
    }

    @Test func theTypewritersHiddenTailStillHidesTheEndOfTheText() {
        let s = Markdown.attributed("Before $x^2$ after words", theme: theme, ink: nil, hidden: 5)
        let tail = s.attribute(.foregroundColor, at: s.length - 1, effectiveRange: nil) as? NSColor
        #expect(tail == NSColor.clear && attachments(s).count == 1)
    }

    @Test func aBubbleWithAFormulaIsTallerThanTheSameLineWithout() {
        let plain = BubbleText(width: 300)
        let math = BubbleText(width: 300)
        let a = plain.setContent(Markdown.attributed("The value is a over b today.", theme: theme, ink: nil))
        let b = math.setContent(Markdown.attributed("The value is $\\frac{a}{b}$ today.", theme: theme, ink: nil))
        #expect(b > a)  // the fraction makes the line taller
    }

    @Test func theCardGetsFormulasToo() {
        let s = Markdown.attributed("Take $x^2$.", theme: theme, ink: 1)
        #expect(attachments(s).count == 1 && attachments(s)[0].ink == 1)
    }
}
