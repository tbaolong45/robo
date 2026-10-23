// LaTeX formulas in a reply, typeset by SwiftMath (Core Text and its Latin Modern Math font) and put in the text as inline images. A formula
// is drawn in the colour of the text around it, and that colour is not fixed: the chat's text follows its panel's light or dark look. So each
// formula is rendered twice (dark ink for a light glass, light ink for a dark one) and `MathCell` picks the one that suits where it is
// drawn, at draw time: no rebuild when the glass turns over. The card, whose ink is a level of its own (`Chrome.ink`), passes that level.
import AppKit
import RoboCore
import SwiftMath

final class MathPiece {
    let size: CGSize
    let descent: CGFloat  // how far the formula reaches below the baseline of the line it stands on
    let onLight: NSImage  // dark ink, for a light glass
    let onDark: NSImage  // light ink, for a dark glass

    init(size: CGSize, descent: CGFloat, onLight: NSImage, onDark: NSImage) {
        (self.size, self.descent, self.onLight, self.onDark) = (size, descent, onLight, onDark)
    }
}

enum Math {
    static let darkInk = NSColor(white: 0.07, alpha: 1), lightInk = NSColor(white: 0.96, alpha: 1)
    nonisolated(unsafe) private static let cache = NSCache<NSString, MathPiece>()

    /// The formula typeset at `fontSize`, or nil when it is not valid LaTeX (the text then stays as the author wrote it). A formula wider
    /// than `maxWidth` is set smaller, down to 60 %, so that it fits the column.
    @MainActor
    static func piece(_ latex: String, fontSize: CGFloat, display: Bool, maxWidth: CGFloat) -> MathPiece? {
        guard var piece = make(latex, fontSize: fontSize, display: display) else { return nil }
        if piece.size.width > maxWidth, maxWidth > 0 {
            let scale = max(0.6, maxWidth / piece.size.width)
            piece = make(latex, fontSize: (fontSize * scale).rounded(.down), display: display) ?? piece
        }
        return piece
    }

    @MainActor
    private static func make(_ latex: String, fontSize: CGFloat, display: Bool) -> MathPiece? {
        let key = "\(display ? "D" : "T")\(fontSize)|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let mode: MTMathUILabelMode = display ? .display : .text
        // the measure: ascent and descent of the typeset list (the image alone does not tell where the baseline is)
        let label = MTMathUILabel()
        label.latex = latex
        label.fontSize = fontSize
        label.labelMode = mode
        label.contentInsets = NSEdgeInsets()
        guard label.error == nil else { return nil }
        label.frame = CGRect(origin: .zero, size: label.fittingSize)
        label.layout()
        guard let list = label.displayList, list.width > 0 else { return nil }
        func image(_ ink: NSColor) -> NSImage? {
            let (error, image) = MTMathImage(latex: latex, fontSize: fontSize, textColor: ink, labelMode: mode).asImage()
            return error == nil ? image : nil
        }
        guard let onLight = image(darkInk), let onDark = image(lightInk), onLight.size.width > 0 else { return nil }
        let piece = MathPiece(size: onLight.size, descent: max(0, list.descent), onLight: onLight, onDark: onDark)
        cache.setObject(piece, forKey: key)
        return piece
    }

    /// `text` with every placeholder of `spans` (see `Latex`) replaced by its formula, typeset in `font`; a formula that does not typeset
    /// goes back as the author wrote it (with its dollar signs), as plain text in the same attributes. A display formula that is a
    /// paragraph of its own is centred. `ink`: the card's ink level, or nil for the chat (the look of the view it is drawn in decides).
    @MainActor
    static func restore(in text: NSMutableAttributedString, spans: [Latex.Span], font: NSFont, ink: Double?, maxWidth: CGFloat) {
        for found in Latex.placeholders(in: text.string).reversed() where spans.indices.contains(found.index) {
            let span = spans[found.index]
            var attributes = text.attributes(at: found.range.location, effectiveRange: nil)
            attributes[.font] = font
            guard let piece = piece(span.source, fontSize: font.pointSize * (span.display ? 1.15 : 1), display: span.display, maxWidth: maxWidth) else {
                let raw = span.display ? "$$\(span.source)$$" : "$\(span.source)$"
                text.replaceCharacters(in: found.range, with: NSAttributedString(string: raw, attributes: attributes))
                continue
            }
            let attachment = NSTextAttachment()
            attachment.attachmentCell = MathCell(piece: piece, ink: ink)
            let ns = text.string as NSString
            let paragraph = ns.paragraphRange(for: found.range)
            let alone = span.display && ns.substring(with: paragraph).trimmingCharacters(in: .newlines).utf16.count == found.range.length
            let glyph = NSMutableAttributedString(attachment: attachment)
            glyph.addAttributes(attributes, range: NSRange(location: 0, length: glyph.length))
            text.replaceCharacters(in: found.range, with: glyph)
            // The paragraph's lines may be as tall as the formula needs (the text's own style caps a line at its font's height, which
            // would squash a fraction), and a display formula that stands alone is centred.
            let style = ((attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.maximumLineHeight = 0
            if alone { style.alignment = .center }
            let now = (text.string as NSString).paragraphRange(for: NSRange(location: found.range.location, length: glyph.length))
            text.addAttribute(.paragraphStyle, value: style, range: now)
        }
    }
}

/// The attachment cell of a formula: it has the size of the typeset formula, sits on the baseline, and draws the image of the ink that suits
/// the view it is drawn in.
final class MathCell: NSTextAttachmentCell {
    let piece: MathPiece
    let ink: Double?

    init(piece: MathPiece, ink: Double?) {
        (self.piece, self.ink) = (piece, ink)
        super.init(imageCell: nil)
    }
    required init(coder: NSCoder) { fatalError("not used") }

    override func cellSize() -> NSSize { piece.size }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -piece.descent) }

    /// Dark ink on a light surface. The card's ink level decides when it has one (it paints its own colours); otherwise the look of the view.
    func darkInk(in view: NSView?) -> Bool {
        if let ink { return ink >= 0.5 }
        return view?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        (darkInk(in: controlView) ? piece.onLight : piece.onDark)
            .draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
