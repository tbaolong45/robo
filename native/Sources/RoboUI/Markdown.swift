// A reply's Markdown as styled rich text, and the text boxes that show it. Port of widgets.style_markdown, hud.md_look
// and widgets._text_height. Foundation parses the Markdown (`AttributedString(markdown:)`, full syntax); this file turns
// the blocks into an NSAttributedString with the spacing and colours Qt's QTextDocument got from `style_markdown`:
// paragraph gap 8, list gap 3, heading gap 4, list indent 18 (+6 when the body is monospace), headings bold in the head colour,
// the theme's line height as a percent, code lines forming one full-width box with an 8 px indent, inline code and links
// in the theme's colours, rules, task boxes, quotes (indented 40 on both sides) and tables as Qt draws them.
//
// The character count matches Qt's: blocks are joined by one "\n" (Qt: one separator), a hard break is one character,
// and list bullets, task boxes and rules are drawn by the layout manager, not typed into the text; a table is a block per
// cell with an empty block after it (and before it when it starts the text), as in Qt, so the typewriter's `hidden`
// (characters from the end that are laid out but painted transparent) means the same here.
import AppKit
import RoboCore

extension NSAttributedString.Key {
    /// A code line's box (an NSColor): filled across the whole width by `RoboLayoutManager`.
    static let codeBox = NSAttributedString.Key("robo.codeBox")
    /// The marker of a list item ("disc", "circle", "square", "box", "checked" or "3."), drawn left of the item's first line.
    static let listMarker = NSAttributedString.Key("robo.listMarker")
    /// On the "\n" that ends an empty rule paragraph (an NSColor): a 1 px line across the width. `ruleEnd` sits on the last
    /// character when the rule is the last block, which has no character of its own.
    static let rule = NSAttributedString.Key("robo.rule")
    static let ruleEnd = NSAttributedString.Key("robo.ruleEnd")
    /// On the last character when the text ends with an empty block (a dictionary of attributes): how tall that empty line is.
    static let trailing = NSAttributedString.Key("robo.trailing")
    /// `InlineBox`: the tint behind `inline code`.
    static let inlineBox = NSAttributedString.Key("robo.inlineBox")
}

/// What `RoboLayoutManager` paints behind inline code: Qt fills the line's own height (the body font's ascent and descent,
/// without the extra line spacing), where NSAttributedString's background would fill the whole line fragment.
final class InlineBox: NSObject {
    let colour: NSColor, ascent: CGFloat, descent: CGFloat
    init(_ colour: NSColor, body: NSFont) { self.colour = colour; (ascent, descent) = Chrome.metrics(body) }
    // equal boxes make equal texts (the styling is a pure function of the Markdown and the theme)
    override func isEqual(_ other: Any?) -> Bool { (other as? InlineBox).map { ($0.colour, $0.ascent, $0.descent) == (colour, ascent, descent) } ?? false }
    override var hash: Int { colour.hash ^ Int(ascent) ^ Int(descent) << 8 }
}

enum Markdown {
    static let gap: CGFloat = 8, listGap: CGFloat = 3, headingGap: CGFloat = 4  // px below a paragraph / between list items / under a heading
    static let headPx: [Int: CGFloat] = [1: 17, 2: 16, 3: 15]  // widgets.HEAD_PX: heading sizes, 14 below
    static let indent: CGFloat = 18  // px per list level (Qt's 40 px wastes a sixth of the bubble)
    static let quoteIndent: CGFloat = 40  // Qt's block quote margin, on both sides

    // MARK: blocks

    private struct Inline {
        var text: String
        var bold = false, italic = false, code = false, strike = false, underline = false
        var link: URL?
    }

    private struct Block {
        enum Kind: Equatable { case paragraph, heading(Int), code, rule, cell, tableGap }
        var kind: Kind
        var inlines: [Inline] = []
        var lists = 0, quotes = 0  // nesting: the indent in levels
        var marker: String?  // the list item's bullet, on the first block of the item
        var inList = false
        var table = 0, row = 0, column = 0, columns = 0  // a table cell: where it sits
    }

    /// Inline HTML as Qt reads it: bold, italic, underline and links count, a line break breaks, every other tag is dropped.
    private struct Html {
        var bold = 0, italic = 0, underline = 0
        var link: [URL?] = []

        /// The tags and the text between them of raw HTML; `apply` is called with the text pieces and the break.
        mutating func feed(_ raw: String, into out: inout [Inline]) {
            var text = "", tag = "", inTag = false
            func flush(_ me: Html) { if !text.isEmpty { out.append(Inline(text: text, bold: me.bold > 0, italic: me.italic > 0, underline: me.underline > 0, link: me.link.last ?? nil)); text = "" } }
            for ch in raw {
                if inTag {
                    if ch == ">" { inTag = false; flush(self); handle(tag, &out); tag = "" } else { tag.append(ch) }
                } else if ch == "<" { inTag = true } else { text.append(ch) }
            }
            if inTag { text += "<" + tag }
            flush(self)
        }

        private mutating func handle(_ tag: String, _ out: inout [Inline]) {
            let closing = tag.hasPrefix("/")
            let name = tag.drop(while: { $0 == "/" }).prefix(while: { $0.isLetter || $0.isNumber }).lowercased()
            let delta = closing ? -1 : 1
            switch name {
            case "b", "strong": bold = max(0, bold + delta)
            case "i", "em": italic = max(0, italic + delta)
            case "u": underline = max(0, underline + delta)
            case "br": out.append(Inline(text: "\u{2028}"))
            case "a":
                if closing { _ = link.popLast() } else {
                    let href = tag.range(of: #"href\s*=\s*["']([^"']*)["']"#, options: .regularExpression).map { String(tag[$0]) }
                    link.append(href.flatMap { $0.split(whereSeparator: { "\"'".contains($0) }).dropFirst().first }.flatMap { URL(string: String($0)) })
                }
            default: break
            }
        }
    }

    private static func parse(_ markdown: String) -> [Block] {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return markdown.isEmpty ? [] : [Block(kind: .paragraph, inlines: [Inline(text: markdown)])]
        }
        var blocks: [Block] = []
        var current: Int?
        var items = Set<Int>()
        var html = Html()
        var raw = 0  // raw HTML blocks have no identity of their own
        func isItem(_ c: PresentationIntent.IntentType) -> Bool { if case .listItem = c.kind { return true } else { return false } }
        for run in parsed.runs {
            let comps = run.presentationIntent?.components ?? []
            let leaf = comps.first
            let intent = run.inlinePresentationIntent ?? []
            var kind = Block.Kind.paragraph
            var key = leaf?.identity ?? -1
            var header = false, cell: (table: Int, row: Int, column: Int, columns: [PresentationIntent.TableColumn])?
            switch leaf?.kind {
            case .header(let level)?: kind = .heading(level)
            case .codeBlock?: kind = .code
            case .thematicBreak?: kind = .rule
            case .tableCell(let column)?:
                kind = .cell
                header = comps.count > 1 && comps[1].kind == .tableHeaderRow
                var row = 0, columns: [PresentationIntent.TableColumn] = []
                if comps.count > 1, case .tableRow(let r) = comps[1].kind { row = r }
                if comps.count > 2, case .table(let c) = comps[2].kind { columns = c }
                cell = (comps.count > 2 ? comps[2].identity : 0, row, column, columns)
            default:
                if leaf == nil && intent.contains(.blockHTML) { raw += 1; key = -1000 - raw }
            }
            if key != current {
                current = key
                html = Html()
                var b = Block(kind: kind)
                b.lists = comps.filter { isItem($0) }.count
                b.quotes = comps.filter { $0.kind == .blockQuote }.count
                b.inList = b.lists > 0
                if let at = comps.firstIndex(where: { isItem($0) }), case .listItem(let ordinal) = comps[at].kind, items.insert(comps[at].identity).inserted {
                    let ordered = at + 1 < comps.count && comps[at + 1].kind == .orderedList
                    b.marker = ordered ? "\(ordinal)." : ["disc", "circle", "square"][min(b.lists, 3) - 1]
                }
                if let cell {
                    (b.table, b.row, b.column, b.columns) = (cell.table, cell.row, cell.column, cell.columns.count)
                }
                blocks.append(b)
            }
            let text = String(parsed[run.range].characters)
            if intent.contains(.inlineHTML) || (leaf == nil && intent.contains(.blockHTML)) {  // raw HTML: its tags are read, not shown
                var pieces: [Inline] = []
                html.feed(leaf == nil ? text.trimmingCharacters(in: .newlines) : text, into: &pieces)
                blocks[blocks.count - 1].inlines += pieces
                continue
            }
            var inline = Inline(text: intent.contains(.lineBreak) ? "\u{2028}" : text,  // Qt's line separator: one character, no new paragraph
                                bold: intent.contains(.stronglyEmphasized) || header || html.bold > 0, italic: intent.contains(.emphasized) || html.italic > 0,
                                code: intent.contains(.code), strike: intent.contains(.strikethrough), underline: html.underline > 0, link: run.link ?? html.link.last ?? nil)
            if let alt = run.imageURL, text.isEmpty { inline.text = alt.lastPathComponent }
            if kind == .code, inline.text.hasSuffix("\n") { inline.text.removeLast() }  // the block's last newline ends its last line
            blocks[blocks.count - 1].inlines.append(inline)
        }
        // `- [ ] x` and `- [x] x` are boxes, not bullets with brackets
        for i in blocks.indices where blocks[i].marker != nil && blocks[i].kind == .paragraph {
            guard let first = blocks[i].inlines.first?.text else { continue }
            for (prefix, marker) in [("[ ] ", "box"), ("[x] ", "checked"), ("[X] ", "checked")] where first.hasPrefix(prefix) {
                blocks[i].inlines[0].text = String(first.dropFirst(prefix.count))
                blocks[i].marker = marker
            }
        }
        // Qt: a table is followed by an empty block, and starts with one when it starts the text; a rule that starts it has one too
        var out: [Block] = []
        for (i, b) in blocks.enumerated() {
            let startsTable = b.kind == .cell && (i == 0 || blocks[i - 1].kind != .cell || blocks[i - 1].table != b.table)
            if i == 0 && (startsTable || b.kind == .rule) { out.append(Block(kind: startsTable ? .tableGap : .paragraph)) }
            out.append(b)
            if b.kind == .cell && (i + 1 == blocks.count || blocks[i + 1].kind != .cell || blocks[i + 1].table != b.table) { out.append(Block(kind: .tableGap)) }
        }
        return out
    }

    // MARK: look

    private struct Look {
        let text, head, link, codeBg, codeFg, inlineBg, grid: NSColor
        let body: NSFont
        let lineH: CGFloat  // the multiple of the font's line
        let indent: CGFloat

        init(_ t: Theme, ink: Double?) {  // the system's colours: they follow light and dark and the glass behind the card
            text = Chrome.text(ink); head = Chrome.text(ink); link = .linkColor
            codeBg = Chrome.wash(0.07, ink); codeFg = Chrome.text(ink); inlineBg = Chrome.wash(0.10, ink); grid = Chrome.textDim(ink)
            body = .systemFont(ofSize: CGFloat(t.textPx))
            lineH = CGFloat(t.lineH) / 100
            indent = Markdown.indent
        }
    }

    private static func face(_ base: NSFont, bold: Bool, italic: Bool, size: CGFloat? = nil) -> NSFont {
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size ?? base.pointSize) ?? base
    }

    private static let measurer = NSLayoutManager()

    /// Qt's line for a font: its ascent, descent and leading rounded up, but not for the hair over a whole number (17 px bold is
    /// 20.02 here and 20 in Qt).
    private static func qtLine(_ font: NSFont) -> CGFloat { (font.ascender - font.descender + font.leading - 0.05).rounded(.up) }

    /// Qt's proportional line height puts the extra room below the line, where `lineHeightMultiple` would put it above, so
    /// the difference between Qt's line (the font's own line rounded up, times the percent) and AppKit's is the line spacing.
    private static func style(spacing: CGFloat, lines: CGFloat, font: NSFont, head: CGFloat, first: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = spacing; p.headIndent = head; p.firstLineHeadIndent = first
        p.lineBreakMode = .byWordWrapping
        if lines > 0 { p.lineSpacing = max(0, qtLine(font) * lines - measurer.defaultLineHeight(for: font)) }
        p.maximumLineHeight = measurer.defaultLineHeight(for: font)  // a line with an emoji would take the emoji font's taller line, which Qt's does not
        return p
    }

    // MARK: the styled text

    /// `markdown` as rich text in the theme's look. The last `hidden` UTF-16 units are laid out but painted transparent
    /// (the typewriter's unrevealed tail: a word that will not fit the line wraps before it appears). `ink` is the card's (the global
    /// `Chrome.ink`, baked into the colours); the chat window passes nil: the system's own colours, which follow its panel's appearance.
    static func attributed(_ markdown: String, theme t: Theme, ink: Double? = Chrome.ink, hidden: Int = 0) -> NSAttributedString {
        let look = Look(t, ink: ink), blocks = parse(markdown), out = NSMutableAttributedString()
        var tables: [Int: NSTextTable] = [:]
        // Qt's table is as wide as its cells need (text, 4 px of padding each side, 1 px lines); AppKit's would fill the line
        var needs: [Int: [Int: CGFloat]] = [:]
        for b in blocks where b.kind == .cell {
            let text = NSAttributedString(string: b.inlines.map(\.text).joined(), attributes: [.font: face(look.body, bold: b.inlines.first?.bold ?? false, italic: false), .kern: look.body.isFixedPitch ? 0 : Chrome.qtKern(look.body.pointSize)])
            needs[b.table, default: [:]][b.column] = max(needs[b.table]?[b.column] ?? 0, text.size().width.rounded(.up) + 8)
        }
        for (i, b) in blocks.enumerated() {
            let next = i + 1 < blocks.count ? blocks[i + 1] : nil, prev = i > 0 ? blocks[i - 1] : nil
            let piece = NSMutableAttributedString()
            var para: NSParagraphStyle
            var inline: [NSAttributedString.Key: Any] = [:]  // carried to the separator: how this block ends
            switch b.kind {
            case .code:
                // each line is a block of its own in Qt; the lines touch, the last leaves the gap
                let lines = b.inlines.map(\.text).joined().split(separator: "\n", omittingEmptySubsequences: false)
                for (n, line) in lines.enumerated() {
                    let end = n == lines.count - 1
                    let spacing = end && next != nil && next?.kind != .code ? gap : 0
                    var a = Chrome.attrs(Chrome.mono(12), look.codeFg)
                    a[.paragraphStyle] = style(spacing: spacing, lines: look.lineH - 0.12, font: Chrome.mono(12), head: 8, first: 8)
                    a[.codeBox] = look.codeBg
                    piece.append(NSAttributedString(string: String(line), attributes: a))
                    if !end { piece.append(NSAttributedString(string: "\n", attributes: a)) }
                }
                para = style(spacing: 0, lines: 0, font: look.body, head: 0, first: 8)
            case .rule:
                para = style(spacing: next == nil ? 0 : gap, lines: look.lineH, font: look.body, head: 0, first: 0)
                if next != nil { inline[.rule] = look.text }
                else if out.length > 0 { out.addAttribute(.ruleEnd, value: look.text, range: NSRange(location: out.length - 1, length: 1)) }
            case .tableGap:
                // the empty block Qt keeps beside a table: a hair of height, and below the table what is left of its gap
                let tiny = NSFont.systemFont(ofSize: 1)
                let p = NSMutableParagraphStyle()
                p.paragraphSpacing = prev?.kind == .cell && next != nil ? tableGapBelow : 0
                p.maximumLineHeight = measurer.defaultLineHeight(for: tiny)
                para = p
                inline[.font] = tiny
            default:
                let level: Int = { if case .heading(let l) = b.kind { return l } else { return 0 } }()
                let isCell = b.kind == .cell
                var spacing: CGFloat = isCell ? 0 : level > 0 ? headingGap : (b.inList && (next?.inList ?? false)) ? listGap : gap
                if next?.kind == .cell && !isCell { spacing = tableGapAbove }  // Qt: the table starts 1 px under the line above it
                // a heading is its level's size, bold (the line below follows the font: 20/19/18 px against 17 for body text)
                let size = level > 0 ? headPx[level] ?? 14 : look.body.pointSize
                let lineFont = level > 0 ? face(look.body, bold: true, italic: false, size: size) : look.body
                let at = CGFloat(b.lists) * look.indent + CGFloat(b.quotes) * quoteIndent
                let p = NSMutableParagraphStyle()
                let base = style(spacing: next == nil ? 0 : spacing, lines: isCell ? 0 : look.lineH, font: lineFont, head: at, first: at)
                p.setParagraphStyle(base)
                if b.quotes > 0 { p.tailIndent = -CGFloat(b.quotes) * quoteIndent }
                if isCell {
                    let table = tables[b.table] ?? { let n = NSTextTable(); n.numberOfColumns = b.columns; n.collapsesBorders = true; n.layoutAlgorithm = .fixedLayoutAlgorithm; tables[b.table] = n; return n }()
                    let cell = NSTextTableBlock(table: table, startingRow: b.row, rowSpan: 1, startingColumn: b.column, columnSpan: 1)
                    cell.setWidth(1, type: .absoluteValueType, for: .border)
                    cell.setBorderColor(look.grid)
                    cell.setWidth(4, type: .absoluteValueType, for: .padding)
                    cell.setValue((needs[b.table]?[b.column] ?? 8) - 8, type: .absoluteValueType, for: .width)  // as wide as its widest text
                    p.textBlocks = [cell]
                }
                para = p
                for run in b.inlines {
                    // A heading takes the head colour, bold and the level's size whatever its fragments were: italic stays and a link stays
                    // a link, but inline code has neither its tint nor its family and a link no underline (the fixed Python card's pixels)
                    var font = face(look.body, bold: level > 0 || run.bold, italic: run.italic, size: size)
                    var a: [NSAttributedString.Key: Any] = [.foregroundColor: level > 0 ? look.head : look.text, .kern: look.body.isFixedPitch ? 0 : Chrome.qtKern(size)]
                    if run.code {
                        if level == 0 {
                            font = face(Chrome.mono(12), bold: run.bold, italic: run.italic)
                            a[.kern] = 0
                            a[.inlineBox] = InlineBox(look.inlineBg, body: look.body)
                        }
                    }
                    if let url = run.link {
                        a[.link] = url
                        if level == 0 { a[.foregroundColor] = look.link; a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    }
                    if run.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if run.strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    a[.font] = font
                    piece.append(NSAttributedString(string: run.text, attributes: a))
                }
            }
            if case .code = b.kind {} else {
                piece.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: piece.length))
            }
            if let marker = b.marker, piece.length > 0 { piece.addAttribute(.listMarker, value: marker, range: NSRange(location: 0, length: 1)) }
            out.append(piece)
            if next != nil {
                var a = piece.length > 0 ? piece.attributes(at: piece.length - 1, effectiveRange: nil) : [.font: look.body, .paragraphStyle: para]
                a[.listMarker] = nil; a[.link] = nil; a[.inlineBox] = nil; a[.underlineStyle] = nil; a[.strikethroughStyle] = nil
                a.merge(inline) { $1 }
                if piece.length == 0 { a[.paragraphStyle] = para }
                out.append(NSAttributedString(string: "\n", attributes: a))
            }
        }
        if out.length > 0, let last = blocks.last {  // an empty last block is a line of its own height, not of the default font's
            let tiny = NSFont.systemFont(ofSize: 1), p = NSMutableParagraphStyle()
            p.maximumLineHeight = measurer.defaultLineHeight(for: tiny)
            if last.kind == .tableGap { out.addAttribute(.trailing, value: [NSAttributedString.Key.font: tiny, .paragraphStyle: p] as NSDictionary, range: NSRange(location: out.length - 1, length: 1)) }
            else if last.kind == .rule { out.addAttribute(.trailing, value: [NSAttributedString.Key.font: look.body, .paragraphStyle: style(spacing: 0, lines: look.lineH, font: look.body, head: 0, first: 0)] as NSDictionary, range: NSRange(location: out.length - 1, length: 1)) }
        }
        if hidden > 0 {
            let from = max(0, out.length - hidden), range = NSRange(location: from, length: out.length - from)
            out.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
            out.removeAttribute(.inlineBox, range: range)
            out.removeAttribute(.link, range: range)
        }
        return out
    }

    /// What is left of the gap below a table once the table has its own border and the empty block its hair of height, and the
    /// gap above one (the empty block only; fitted to the Python card's heights: see MarkdownTests).
    static let tableGapBelow: CGFloat = 9.5, tableGapAbove: CGFloat = 1

    /// Plain text (your own quote): one font and colour, no Markdown, and no taller a line for an emoji than Qt's.
    static func plain(_ text: String, font: NSFont, colour: NSColor) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.maximumLineHeight = measurer.defaultLineHeight(for: font)
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour, .paragraphStyle: p,
                                                             .kern: font.isFixedPitch ? 0 : Chrome.qtKern(font.pointSize)])
    }
}

/// Draws what the text system has no attribute for: the full-width code boxes and the list markers.
final class RoboLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage {
            storage.enumerateAttribute(.codeBox, in: characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)) { value, range, _ in
                guard let colour = value as? NSColor else { return }
                colour.setFill()
                let left = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0  // the text indent is part of the box
                enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { rect, _, _, lineGlyphs, _ in
                    // the gap below a block is part of its last line's fragment, not of the box
                    let end = self.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil).upperBound - 1
                    let gap = (storage.attribute(.paragraphStyle, at: end, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing ?? 0
                    let ends = end == storage.length - 1 || storage.string.utf16[storage.string.utf16.index(storage.string.utf16.startIndex, offsetBy: end)] == 10
                    NSRect(x: origin.x + rect.minX + left, y: origin.y + rect.minY, width: rect.width - left, height: rect.height - (ends ? gap : 0)).fill()
                }
            }
        }
        if let storage = textStorage, let tc = textContainers.first {
            storage.enumerateAttribute(.inlineBox, in: characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)) { value, range, _ in
                guard let box = value as? InlineBox else { return }
                let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                box.colour.setFill()
                enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, lineGlyphs, _ in
                    let part = NSIntersectionRange(glyphs, lineGlyphs)
                    guard part.length > 0 else { return }
                    let x = self.boundingRect(forGlyphRange: part, in: tc)
                    let baseline = line.minY + self.location(forGlyphAt: part.location).y
                    NSRect(x: origin.x + x.minX, y: origin.y + baseline - box.ascent, width: x.width, height: box.ascent + box.descent).fill()
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// Qt's rule: 1 px of the text colour across the width, half the line's height down.
    private func drawRule(_ colour: NSColor, in line: NSRect, font: NSFont, at origin: NSPoint) {
        let m = Chrome.metrics(font)
        colour.setFill()
        NSRect(x: origin.x + line.minX, y: origin.y + line.minY + (m.ascent + m.descent) / 2 - 0.5, width: line.width, height: 1).fill()
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        storage.enumerateAttribute(.rule, in: characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)) { value, range, _ in
            guard let colour = value as? NSColor else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 14)
            drawRule(colour, in: lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: range.location), effectiveRange: nil), font: font, at: origin)
        }
        if storage.length > 0, let colour = storage.attribute(.ruleEnd, at: storage.length - 1, effectiveRange: nil) as? NSColor, extraLineFragmentRect != .zero {
            drawRule(colour, in: extraLineFragmentRect, font: storage.attribute(.font, at: storage.length - 1, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 14), at: origin)
        }
        storage.enumerateAttribute(.listMarker, in: characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)) { value, range, _ in
            guard let marker = value as? String else { return }
            let attrs = storage.attributes(at: range.location, effectiveRange: nil)
            let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: 14), colour = attrs[.foregroundColor] as? NSColor ?? .labelColor
            let glyph = glyphIndexForCharacter(at: range.location)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let at = location(forGlyphAt: glyph)
            let x = origin.x + line.minX + at.x, baseline = origin.y + line.minY + at.y  // where the item's text starts
            colour.setFill(); colour.setStroke()
            // QTextDocumentLayout.drawListItem: the marker ends a space before the text, a third of the font's line wide and
            // tall, centred on half the font's height from the top of the line
            let space = Chrome.advance(" ", font), d = Chrome.qtLine(font) / 3
            let m = Chrome.metrics(font)
            let dot = NSRect(x: x - space - d, y: origin.y + line.minY + (m.ascent + m.descent) / 2 - d / 2, width: d, height: d)
            switch marker {
            case "disc": NSBezierPath(ovalIn: dot).fill()
            case "circle": let p = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1; p.stroke()
            case "square": dot.fill()
            case "box", "checked":  // a task: a square of 0.6 line, its border half the text colour, an X in it when done
                let side = (Chrome.qtLine(font) * 0.6).rounded()
                let box = NSRect(x: x - space - side + 0.5, y: origin.y + line.minY + (m.ascent + m.descent) / 2 - side / 2 - 0.5, width: side, height: side)
                colour.withAlphaComponent(colour.alphaComponent * 0.5).setStroke()
                let frame = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 1.5, yRadius: 1.5); frame.lineWidth = 1; frame.stroke()
                if marker == "checked" {
                    let cross = NSBezierPath()
                    cross.move(to: NSPoint(x: box.minX + 2.5, y: box.minY + 2.5)); cross.line(to: NSPoint(x: box.maxX - 2.5, y: box.maxY - 2.5))
                    cross.move(to: NSPoint(x: box.maxX - 2.5, y: box.minY + 2.5)); cross.line(to: NSPoint(x: box.minX + 2.5, y: box.maxY - 2.5))
                    cross.lineWidth = 1.4; colour.setStroke(); cross.stroke()
                }
            default:
                let s = NSAttributedString(string: marker, attributes: [.font: font, .foregroundColor: colour])
                s.draw(at: NSPoint(x: x - space - s.size().width, y: baseline - font.ascender))
            }
        }
    }
}

/// A text view that never edits, opens links itself, and tells a plain click from a selection or a link click.
final class BoxTextView: NSTextView {
    var onClick: (() -> Void)?  // a left click within `Self.slop`, not on a link, selecting nothing
    var openLink: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Asked before a link opens, with its full address and the words that showed it; true opens. The reply is text from mail,
    /// Teams and Moodle that a model wrote, so `[grades](https://evil.example/?d=SECRET)` must not leave on one stray click.
    /// The default is an alert; a test that clicks a link replaces this too, so that none shows.
    var confirmLink: (URL, String) -> Bool = BoxTextView.askToOpen
    /// The reply is text from mail, Teams and Moodle that a model wrote, so a link in it is not trusted to name a file, a share
    /// or an app: only these schemes are opened.
    static let schemes: Set<String> = ["http", "https", "mailto"]
    static let slop: CGFloat = 4  // px a press and release may be apart and still be a click (SKIP_PX)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func clicked(onLink link: Any, at charIndex: Int) {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)), let scheme = url.scheme?.lowercased(),
              Self.schemes.contains(scheme) else { return }
        if confirmLink(url, linkText(at: charIndex)) { openLink(url) }
    }

    /// The words of the link at `index` (what the reader saw); empty when there is no link there.
    private func linkText(at index: Int) -> String {
        guard let storage = textStorage, index >= 0, index < storage.length else { return "" }
        var range = NSRange()
        guard storage.attribute(.link, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) != nil else { return "" }
        return (storage.string as NSString).substring(with: range)
    }

    /// The default `confirmLink`: an alert with the full address first, then the words when they say something else. Cancel is the
    /// default button, so a stray key opens nothing. With no running app (a test) nothing is asked and the answer is no.
    static func askToOpen(_ url: URL, _ words: String) -> Bool {
        guard NSApplication.shared.isRunning else { return false }
        let text = alertText(for: url, words: words)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.title
        alert.informativeText = text.body
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: text.open)
        let front = Focus().other()  // an accessory app takes the activation to show the alert and gives it back when nothing opens
        NSApp.activate()
        let open = alert.runModal() == .alertSecondButtonReturn
        if !open { Focus().handBack(to: front) }
        return open
    }

    /// What the alert says: the full address, the words that showed it when they say something else, and what the source check
    /// (`SourceCheck`, offline) found: a known source, a look-alike, a link whose words name another site, a shortened link... A link that
    /// looks like a scam is named so, and its button says "Open anyway"; Cancel is still the default.
    static func alertText(for url: URL, words: String) -> (title: String, body: String, open: String) {
        let address = url.absoluteString
        var body = address + (words.isEmpty || words == address ? "" : "\n\nThe link text says “\(words.prefix(120))”.")
        let verdict = SourceCheck.assess(url: address, words: words)
        if let notice = SourceCheck.linkNotice(url: address, words: words) { body += "\n\n" + notice }
        return (verdict.level == .scam ? "This link looks like a scam" : "Open this link?", body, verdict.warns ? "Open anyway" : "Open")
    }

    /// NSTextView tracks the whole press-drag-release inside `mouseDown`, so the release (the last event the tracking loop took)
    /// is read afterwards.
    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        let up = NSApp.currentEvent.flatMap { $0.type == .leftMouseUp ? $0.locationInWindow : nil } ?? window?.mouseLocationOutsideOfEventStream
        click(from: start, to: up.map { convert($0, from: nil) } ?? start)
    }

    /// The skip-click rule of `app._skip_click`: a click, not on a link, with nothing selected.
    func click(from start: NSPoint, to end: NSPoint) {
        if abs(end.x - start.x) + abs(end.y - start.y) < Self.slop && !isLink(at: end) && selectedRange().length == 0 { onClick?() }
    }

    /// `QTextBrowser.anchorAt`: is there a link under `point` (view coordinates)?
    func isLink(at point: NSPoint) -> Bool {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return false }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = lm.glyphIndex(for: p, in: tc)
        guard lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).contains(p) else { return false }
        return storage.attribute(.link, at: lm.characterIndexForGlyph(at: glyph), effectiveRange: nil) != nil
    }
}

/// The scroll bar of the style sheet: a 5 px track-less strip with a rounded handle in the accent colour.
final class KnobScroller: NSScroller {
    var knob = NSColor.gray { didSet { needsDisplay = true } }
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 5 }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func draw(_ dirtyRect: NSRect) {
        guard usableParts != .noScrollerParts else { return }
        var r = rect(for: .knob)
        if r.height < 18 { r.size.height = 18 }
        knob.setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.maxX - 5, y: r.minY, width: 5, height: r.height), xRadius: 2, yRadius: 2).fill()
    }
}

/// A text box as tall as its text, up to a cap, then it scrolls (the reply and the quote's text). The text container
/// is as wide as the box, 5 px less while the scroll bar shows; it never edits.
final class TextBox: NSScrollView {
    let textView: BoxTextView
    private let layout = RoboLayoutManager()
    private let container: NSTextContainer
    let boxWidth: CGFloat
    private(set) var overflows = false
    private(set) var documentHeight: CGFloat = 0
    private var trailing: [NSAttributedString.Key: Any]?
    private(set) var widthChanges = 0  // how often the text was laid out again at the other width (a text that overflows must not do it per tick)

    init(width: CGFloat) {
        boxWidth = width
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        textView = BoxTextView(frame: NSRect(x: 0, y: 0, width: width, height: 0), textContainer: container)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        textView.isEditable = false; textView.isSelectable = true; textView.drawsBackground = false
        textView.textContainerInset = .zero; textView.isRichText = true; textView.allowsUndo = false
        textView.isVerticallyResizable = false; textView.isHorizontallyResizable = false; textView.autoresizingMask = []
        drawsBackground = false; borderType = .noBorder; hasHorizontalScroller = false; hasVerticalScroller = false
        verticalScroller = KnobScroller()
        scrollerStyle = .legacy
        autohidesScrollers = false
        contentView.drawsBackground = false
        documentView = textView
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    var isBlank: Bool { textView.textStorage?.length == 0 }
    var length: Int { textView.textStorage?.length ?? 0 }
    var string: String { textView.string }

    func style(_ t: Theme) {
        textView.selectedTextAttributes = [.backgroundColor: Chrome.accent(t, t.hue, 0.35), .foregroundColor: Chrome.text]
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        (verticalScroller as? KnobScroller)?.knob = Chrome.accent(t, t.hue, 0.45)
    }

    func setContent(_ s: NSAttributedString) {
        textView.textStorage?.setAttributedString(s)
        trailing = s.length > 0 ? s.attribute(.trailing, at: s.length - 1, effectiveRange: nil) as? [NSAttributedString.Key: Any] : nil
        if let trailing { textView.typingAttributes = trailing }  // the empty last line takes its height from these
        relayout()  // at the width it had: `wantedHeight` decides whether that changes
    }

    private func relayout() {
        if hasVerticalScroller != overflows { hasVerticalScroller = overflows }
        let width = boxWidth - (overflows ? 5 : 0)
        if container.containerSize.width != width { container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude); widthChanges += 1 }
        layout.ensureLayout(for: container)
        // AppKit leaves the line spacing off the last line of the text; Qt's proportional height keeps it
        let lastStyle = (trailing?[.paragraphStyle] ?? (length > 0 ? textView.textStorage?.attribute(.paragraphStyle, at: length - 1, effectiveRange: nil) : nil)) as? NSParagraphStyle
        let last = length > 0 ? lastStyle?.lineSpacing ?? 0 : 0
        documentHeight = isBlank ? 0 : layout.usedRect(for: container).height + last  // an empty text has no height (AppKit keeps one empty line)
        textView.setFrameSize(NSSize(width: container.containerSize.width, height: max(documentHeight.rounded(.up), frame.height)))
    }

    /// `_text_height`: 0 when empty, else the height that shows all the text plus 2, at most `cap`. A text that needs
    /// the cap gets the scroll bar (which takes 5 px of the width, as in Qt). The width the text was last laid out at is kept
    /// between calls: only near the cap can the other width change the answer, so only there is it tried.
    func wantedHeight(cap: CGFloat) -> CGFloat {
        guard !isBlank else { overflows = false; relayout(); return 0 }
        relayout()
        var h = CGFloat(Int(documentHeight)) + 2
        if overflows {
            guard h <= cap * 1.1 + 40 else { return cap }  // far above the cap, five pixels of width do not bring it under
            overflows = false; relayout()
            h = CGFloat(Int(documentHeight)) + 2
        }
        if h > cap { overflows = true; relayout() }
        return min(h, cap)
    }

    func setBoxHeight(_ h: CGFloat) {
        setFrameSize(NSSize(width: boxWidth, height: h))
        relayout()
        scrollValue = scrollValue
    }

    var scrollMaximum: CGFloat { max(0, textView.frame.height - contentView.bounds.height) }
    var scrollValue: CGFloat {
        get { contentView.bounds.origin.y }
        set {
            contentView.scroll(to: NSPoint(x: 0, y: min(max(0, newValue), scrollMaximum)))
            reflectScrolledClipView(contentView)
        }
    }

    /// The text cursor's rectangle at character `index` in viewport coordinates (`QTextEdit.cursorRect`).
    func cursorRect(at index: Int) -> CGRect {
        layout.ensureLayout(for: container)
        let n = layout.numberOfGlyphs
        var r: CGRect
        if n == 0 {
            r = CGRect(x: 0, y: 0, width: 1, height: (textView.font ?? .systemFont(ofSize: 14)).boundingRectForFont.height)
        } else if index >= length {  // after the last character
            let g = NSRange(location: n - 1, length: 1)
            let line = layout.lineFragmentRect(forGlyphAt: n - 1, effectiveRange: nil)
            r = CGRect(x: layout.boundingRect(forGlyphRange: g, in: container).maxX, y: line.minY, width: 1, height: line.height)
        } else {
            let g = layout.glyphIndexForCharacter(at: index)
            let line = layout.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            r = CGRect(x: line.minX + layout.location(forGlyphAt: g).x, y: line.minY, width: 1, height: line.height)
        }
        return r.offsetBy(dx: -contentView.bounds.origin.x, dy: -contentView.bounds.origin.y)  // the viewport scrolls under the text
    }
}
