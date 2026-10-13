// Port of tests/test_widgets.py (`style_markdown`, `md_look`, `_text_height`) and of the character counts Qt's QTextDocument gave
// (checked in Python: the typewriter's `hidden` is a count of them). Not ported: the "default look" tests (there is only the themed
// look), the "styling twice changes nothing" tests become "the function is pure", and the font-family/no-QApplication tests (Qt-only).
import AppKit
import Foundation
import Testing
@testable import RoboCore
@testable import RoboUI

/// 58 inputs and what Qt's QTextDocument.toPlainText gave for each (Python, `setMarkdown`; the corpus of the card review).
private let qtCorpus: [(String, String)] = [
    ("Hello\u{a}world", "Hello world"),
    ("Hello  \u{a}world", "Hello\u{a}world"),
    ("Hello\\\u{a}world", "Hello\u{a}world"),
    ("# H1\u{a}\u{a}text", "H1\u{a}text"),
    ("## Sub **bold** head\u{a}text right after", "Sub bold head\u{a}text right after"),
    ("- a\u{a}- b\u{a}  - c\u{a}- d", "a\u{a}b\u{a}c\u{a}d"),
    ("1. one\u{a}2. two\u{a}3. three", "one\u{a}two\u{a}three"),
    ("- [ ] todo\u{a}- [x] done", "todo\u{a}done"),
    ("> quote\u{a}> more\u{a}\u{a}after", "quote more\u{a}after"),
    ("---", "\u{a}"),
    ("a\u{a}\u{a}---\u{a}\u{a}b", "a\u{a}\u{a}b"),
    ("| h1 | h2 |\u{a}|----|----|\u{a}| a | b |\u{a}| c | d |", "\u{a}h1\u{a}h2\u{a}a\u{a}b\u{a}c\u{a}d\u{a}"),
    ("```py\u{a}x = 1\u{a}y = 2\u{a}```", "x = 1\u{a}y = 2"),
    ("```\u{a}no lang\u{a}```\u{a}text after fence", "no lang\u{a}text after fence"),
    ("`code`", "code"),
    ("**bold** *it* ~~del~~ ***both***", "bold it del both"),
    ("[link](http://x.y)", "link"),
    ("<http://auto.link>", "http://auto.link"),
    ("see http://bare.example.com now", "see http://bare.example.com now"),
    ("![alt text](http://x/y.png)", "\u{fffc}"),
    ("<b>x</b> text", "x text"),
    ("a &amp; b &lt; c", "a & b < c"),
    ("\\*not italic\\*", "*not italic*"),
    ("Setext\u{a}=====\u{a}\u{a}text", "Setext\u{a}text"),
    ("Sub\u{a}-----\u{a}\u{a}text", "Sub\u{a}text"),
    ("- a\u{a}\u{a}- b\u{a}\u{a}- c", "a\u{a}b\u{a}c"),
    ("1) paren\u{a}2) list", "paren\u{a}list"),
    ("1. step\u{a}\u{a}   ```\u{a}   code in list\u{a}   ```\u{a}\u{a}2. next", "step\u{a}code in list\u{a}next"),
    ("", ""),
    ("\u{a}\u{a}", ""),
    ("  ", ""),
    ("line1\u{a}\u{a}\u{a}\u{a}line2", "line1\u{a}line2"),
    ("\u{1f600} **ok** \u{2705} done", "\u{1f600} ok \u{2705} done"),
    ("* star\u{a}* two", "star\u{a}two"),
    ("+ plus\u{a}+ two", "plus\u{a}two"),
    ("text\u{a}- immediately list\u{a}- two", "text\u{a}immediately list\u{a}two"),
    ("1. a\u{a}   continuation\u{a}2. b", "a continuation\u{a}b"),
    ("Price: $5 and $10, 5 * 3 * 2", "Price: $5 and $10, 5 * 3 * 2"),
    ("    indented code\u{a}    more", "indented code\u{a}more"),
    ("~~~\u{a}tilde\u{a}~~~", "tilde"),
    ("Here's the plan:\u{a}\u{a}1. **Step** one\u{a}2. Step two\u{a}\u{a}```\u{a}code\u{a}```\u{a}Done.", "Here's the plan:\u{a}Step one\u{a}Step two\u{a}code\u{a}Done."),
    ("- item with `code` and [link](http://a.b)\u{a}- second", "item with code and link\u{a}second"),
    ("**Bold:** value\u{a}**Other:** value2", "Bold: value Other: value2"),
    ("Line one\u{a}Line two\u{a}Line three", "Line one Line two Line three"),
    ("- a\u{a}  continued\u{a}- b", "a continued\u{a}b"),
    ("* **Mon** \u{2014} Physics lab\u{a}* **Tue** \u{2014} Quiz", "Mon \u{2014} Physics lab\u{a}Tue \u{2014} Quiz"),
    ("| a |\u{a}|---|\u{a}| b |\u{a}\u{a}text", "\u{a}a\u{a}b\u{a}\u{a}text"),
    ("# Title\u{a}## Sub\u{a}### Subsub\u{a}text", "Title\u{a}Sub\u{a}Subsub\u{a}text"),
    ("a\\\u{a}b", "a\u{a}b"),
    ("- nested\u{a}    - deep\u{a}        - deeper", "nested\u{a}deep\u{a}deeper"),
    ("10. ten\u{a}11. eleven", "ten\u{a}eleven"),
    ("> - quoted list\u{a}> - two", "quoted list\u{a}two"),
    ("Text with trailing spaces   \u{a}", "Text with trailing spaces"),
    ("foo<br>bar", "foo"),
    ("[ref]: http://x.y\u{a}\u{a}[ref]", "ref"),
    ("word1  word2   word3", "word1  word2   word3"),
    ("\u{9}tabbed", "tabbed"),
    ("term\u{a}: def", "term : def"),
]

private let sample = "# Title\n\npara `code` [link](https://x.y) **bold**\n\n- a\n  - b\n- c\n\n```python\nx = 1\ny = 2\n```\n\nend"

private func rgb(_ c: NSColor) -> [Int] {
    let s = c.usingColorSpace(.sRGB)!
    return [s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent].map { Int(($0 * 255).rounded()) }
}
private func hex(_ token: String) -> [Int] { let c = Themes.rgba(token); return [Int(c.r), Int(c.g), Int(c.b), 255] }

/// The paragraphs of a styled text: the string without its separator, and the attributes of its first character.
private func blocks(_ s: NSAttributedString) -> [(text: String, attrs: [NSAttributedString.Key: Any])] {
    var out: [(String, [NSAttributedString.Key: Any])] = [], start = 0
    let text = s.string as NSString
    while start <= text.length {
        let end = text.range(of: "\n", range: NSRange(location: start, length: text.length - start)).location
        let stop = end == NSNotFound ? text.length : end
        out.append((text.substring(with: NSRange(location: start, length: stop - start)), s.length > 0 ? s.attributes(at: min(start, s.length - 1), effectiveRange: nil) : [:]))
        if end == NSNotFound { break }
        start = end + 1
    }
    return out
}
private func spacing(_ a: [NSAttributedString.Key: Any]) -> CGFloat { (a[.paragraphStyle] as! NSParagraphStyle).paragraphSpacing }
private func indent(_ a: [NSAttributedString.Key: Any]) -> CGFloat { (a[.paragraphStyle] as! NSParagraphStyle).firstLineHeadIndent }
private func font(_ a: [NSAttributedString.Key: Any]) -> NSFont { a[.font] as! NSFont }
private func bold(_ f: NSFont) -> Bool { f.fontDescriptor.symbolicTraits.contains(.bold) }
private func italic(_ f: NSFont) -> Bool { f.fontDescriptor.symbolicTraits.contains(.italic) }
private func run(_ s: NSAttributedString, _ needle: String) -> [NSAttributedString.Key: Any] {
    s.attributes(at: (s.string as NSString).range(of: needle).location, effectiveRange: nil)
}
private func md(_ text: String, _ t: Theme = Themes.cyan, hidden: Int = 0) -> NSAttributedString { Markdown.attributed(text, theme: t, hidden: hidden) }

@Suite @MainActor struct MarkdownStyleTests {
    init() { _ = NSApplication.shared }  // AppKit text and scrolling need the application object

    @Test func paragraphsHaveAGapBelowAndTheLastBlockLeavesNoBand() {
        let b = blocks(md("one\n\ntwo"))
        #expect(b.map(\.text) == ["one", "two"])
        #expect(spacing(b[0].attrs) == Markdown.gap && spacing(b[1].attrs) == 0)
    }

    @Test func aListIsTightInsideAndGappedFromTheParagraphAfterIt() {
        let b = blocks(md("- a\n- b\n\nafter"))
        #expect(b.map(\.text) == ["a", "b", "after"])
        #expect(spacing(b[0].attrs) == Markdown.listGap)
        #expect(spacing(b[1].attrs) == Markdown.gap)  // the list's end
        #expect(spacing(b[2].attrs) == 0)
    }

    @Test func aHeadingSitsCloseToWhatItIntroduces() {
        let b = blocks(md("## Today\n\nthings"))
        #expect(spacing(b[0].attrs) == Markdown.headingGap && spacing(b[1].attrs) == 0)
    }

    @Test func codeLinesFormADarkMonospaceBox() {
        let t = Themes.cyan, s = md("before\n\n```python\ndef f():\n    return 1\n```\n\nafter")
        let b = blocks(s)
        #expect(b.map(\.text) == ["before", "def f():", "    return 1", "after"])
        for line in [b[1], b[2]] {
            #expect(rgb(line.attrs[.codeBox] as! NSColor) == hex(t.codeBg))
            #expect(indent(line.attrs) == 8)  // padding at the left of the box
            #expect(font(line.attrs).pointSize == 12 && font(line.attrs).fontName.contains(Chrome.monoFamily.replacingOccurrences(of: " ", with: "")))
            #expect(rgb(line.attrs[.foregroundColor] as! NSColor) == hex(t.codeFg))
        }
        #expect(spacing(b[1].attrs) == 0)  // the lines touch: one box
        #expect(spacing(b[2].attrs) == Markdown.gap)
        #expect(b[0].attrs[.codeBox] == nil && b[3].attrs[.codeBox] == nil)
    }

    @Test func longCodeLinesWrapInsteadOfForcingASideways() {
        let box = TextBox(width: 302)
        box.setContent(md("```\n" + String(repeating: "find . -name '*.plist' | xargs ls -la ", count: 5) + "\n```"))
        #expect(box.textView.frame.width == 302 && box.documentHeight > 3 * 14)  // wrapped onto several lines, nothing sticks out
    }

    @Test func inlineCodeAndLinksAreReadableOnTheDarkPanel() {
        let t = Themes.cyan, s = md("run `ls -l` or see [the notes](https://example.com) now")
        let code = run(s, "ls -l"), link = run(s, "the notes"), plain = run(s, "run ")
        #expect((code[.inlineBox] as! InlineBox).colour == Chrome.color(t.inlineBg) && font(code).pointSize == 12)
        #expect(rgb(link[.foregroundColor] as! NSColor) == hex(t.link) && link[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
        #expect((link[.link] as? URL)?.absoluteString == "https://example.com")
        #expect(plain[.inlineBox] == nil && plain[.link] == nil && plain[.underlineStyle] == nil)  // plain text untouched
        #expect(rgb(code[.foregroundColor] as! NSColor) == hex(t.text))  // inline code keeps the text colour; the tint is what the theme guarantees it on
    }

    @Test func theFunctionIsPure() {
        for t in Themes.all { #expect(md(sample, t).isEqual(to: md(sample, t))) }
        #expect(!md(sample, Themes.cyan).isEqual(to: md(sample, Themes.matrix)))
    }

    @Test func aTableIsABlockPerCellWithAnEmptyBlockAfterItAndBeforeItWhenItStartsTheText() {
        let s = md("| a | b |\n|---|---|\n| 1 | 2 |\n\nafter")
        #expect(blocks(s).map(\.text) == ["", "a", "b", "1", "2", "", "after"])  // Qt: "\na\nb\n1\n2\n\nafter"
        #expect(blocks(md("before\n\n| a |\n|---|\n| 1 |\n\nafter")).map(\.text) == ["before", "a", "1", "", "after"])
        let cell = blocks(s)[1].attrs[.paragraphStyle] as! NSParagraphStyle
        #expect(cell.textBlocks.count == 1 && cell.paragraphSpacing == 0 && cell.lineSpacing == 0)  // cells keep their own line
        #expect(bold(font(blocks(s)[1].attrs)) && !bold(font(blocks(s)[3].attrs)))  // the header row is bold
        #expect(spacing(blocks(s)[6].attrs) == 0)  // the paragraph after it is the last block
    }

    @Test func theTableHasQtsGridAndItsHeightsAndTheNextBlockDoesNotTouchIt() {
        // Qt (Python card, cyan): the reply of "table" is 111 px tall (doc 109.7) with a header and two rows, "tableend" 58 (doc 56),
        // and "after" starts 10 px under the last line of the grid; each row is 26 px (17 of text, 4 padding each side, 1 border)
        func height(_ md: String) -> CGFloat { let b = TextBox(width: 302); b.setContent(Markdown.attributed(md, theme: Themes.cyan)); return b.documentHeight }
        #expect(abs(height("| Day | Class |\n|-----|-------|\n| Mon | Physics |\n| Tue | Quiz |\n\nAfter the table.") - 109.7) < 2.5)
        #expect(abs(height("| a | b |\n|---|---|\n| 1 | 2 |") - 56) < 2.5)
        #expect(abs(height("Before.\n\n| a | **b** |\n|:--|--:|\n| 1 | a longer cell |\n\n- item after") - 103.4) < 2.5)
    }

    @Test func aReplyIsStyledInACoupleOfMilliseconds() {
        let reply = String(repeating: "## This week\n\n- *Linear Algebra* set - due Thursday\n- Physics lab report\n\nThe chain rule: `d/dx f(g(x))`.\n\n```python\ndef chain(f, g, x):\n    return f(g(x))\n```\n\nSee [the notes](https://example.com/notes).\n\n", count: 7)
        var best = 1.0
        for _ in 0..<10 {
            let t = ProcessInfo.processInfo.systemUptime
            _ = md(reply, Themes.matrix)
            best = min(best, ProcessInfo.processInfo.systemUptime - t)
        }
        #expect(best < 0.02)  // Python's check; a debug build on a busy machine has the slack
    }

    @Test func emphasisAndStrongAreFontTraitsAndStrikeIsAStrike() {
        let s = md("a *it* **bo** ~~gone~~ ***both***")
        #expect(italic(font(run(s, "it"))) && !bold(font(run(s, "it"))))
        #expect(bold(font(run(s, "bo"))) && !italic(font(run(s, "bo"))))
        #expect(bold(font(run(s, "both"))) && italic(font(run(s, "both"))))
        #expect(run(s, "gone")[.strikethroughStyle] != nil && run(s, "a ")[.strikethroughStyle] == nil)
    }
}

@Suite @MainActor struct MarkdownThemeTests {
    init() { _ = NSApplication.shared }  // AppKit text and scrolling need the application object

    @Test(arguments: Themes.all.map(\.key)) func aThemedLookDressesHeadingsCodeAndLinksInTheThemesColours(_ key: String) {
        let t = Themes.all.first { $0.key == key }!, s = md(sample, t)
        let b = blocks(s)
        #expect(b.map(\.text) == ["Title", "para code link bold", "a", "b", "c", "x = 1", "y = 2", "end"])
        let head = b[0].attrs
        #expect(rgb(head[.foregroundColor] as! NSColor) == hex(t.head) && bold(font(head)))
        let para = b[1].attrs
        #expect((run(s, "code")[.inlineBox] as! InlineBox).colour == Chrome.color(t.inlineBg))
        #expect(rgb(run(s, "link")[.foregroundColor] as! NSColor) == hex(t.link))
        #expect(rgb(b[5].attrs[.codeBox] as! NSColor) == hex(t.codeBg) && rgb(b[5].attrs[.foregroundColor] as! NSColor) == hex(t.codeFg))
        let levelOne = indent(b[2].attrs), nested = indent(b[3].attrs)
        #expect(levelOne == 18 + (t.bodyMono ? 6 : 0) && nested == 2 * levelOne)
        let body = font(para)
        #expect(body.pointSize == CGFloat(t.textPx))
        #expect(body.isFixedPitch == t.bodyMono)
        // the extra of the line height (the percent of Qt's line, rounded up) is the line spacing
        let line = (para[.paragraphStyle] as! NSParagraphStyle).lineSpacing
        #expect(abs(line + NSLayoutManager().defaultLineHeight(for: body) - Chrome.qtLine(body) * CGFloat(t.lineH) / 100) < 0.01)
    }

    @Test func headingsAreBoldInTheHeadColourAtTheirLevelsSize() {
        // widgets.HEAD_PX: 17/16/15 px for H1-H3, 14 below; body text is 14 (Python's card, with the FontSizeAdjustment fix)
        let s = md("# one\n\n## two\n\n### three\n\n#### four\n\nbody")
        let b = blocks(s)
        #expect(b.map { font($0.attrs).pointSize } == [17, 16, 15, 14, 14])
        #expect(b.prefix(4).allSatisfy { bold(font($0.attrs)) && rgb($0.attrs[.foregroundColor] as! NSColor) == hex(Themes.cyan.head) })
        #expect(!bold(font(b[4].attrs)))
        #expect(md("# one", Themes.matrix).attribute(.font, at: 0, effectiveRange: nil).map { ($0 as! NSFont).pointSize } == 17)  // a monospace body too
    }

    @Test func headingLinesAreTallerLikeQts() {
        // Qt (measured on the fixed Python card, cyan): blocks of 20 / 19 / 18 px (H1 / H2 / H3), body 17, each x 1.16
        func line(_ md: String) -> CGFloat {
            let box = TextBox(width: 302)
            box.setContent(Markdown.attributed(md, theme: Themes.cyan))
            return box.documentHeight
        }
        #expect(abs(line("# one") - 20 * 1.16) < 0.6 && abs(line("### three") - 18 * 1.16) < 0.6 && abs(line("body") - 17 * 1.16) < 0.6)
        #expect(line("# one") > line("## two") && line("## two") >= line("### three") && line("### three") > line("body"))
        let gap = TextBox(width: 302); gap.setContent(Markdown.attributed("# one\n\nbody", theme: Themes.cyan))
        #expect(abs(gap.documentHeight - (20 * 1.16 + Markdown.headingGap + 17 * 1.16)) < 1)  // HEADING_GAP is unchanged
    }

    @Test func aHeadingKeepsItalicAndLinksButNotTheCodeFontOrTheUnderline() {
        let s = md("## a *it* `code` [link](https://x.y)")
        #expect(italic(font(run(s, "it"))) && bold(font(run(s, "it"))) && font(run(s, "it")).pointSize == 16)
        #expect(run(s, "code")[.inlineBox] == nil && !font(run(s, "code")).isFixedPitch && font(run(s, "code")).pointSize == 16)
        #expect(run(s, "link")[.link] != nil && rgb(run(s, "link")[.foregroundColor] as! NSColor) == hex(Themes.cyan.head) && run(s, "link")[.underlineStyle] == nil)
    }

    @Test func theListIndentIsEighteenAndSixMoreWhenTheBodyIsMonospace() {
        #expect(indent(blocks(md("- a"))[0].attrs) == 18)
        #expect(indent(blocks(md("- a", Themes.matrix))[0].attrs) == 24)
        #expect(indent(blocks(md("para"))[0].attrs) == 0)
    }

    @Test func theLineHeightExtraGoesBelowTheLineAsInQt() {
        let p = blocks(md("para"))[0].attrs[.paragraphStyle] as! NSParagraphStyle
        #expect(p.lineSpacing > 0 && p.lineHeightMultiple == 0)  // lineHeightMultiple would put it above
        let code = blocks(md("```\nx\n```"))[0].attrs[.paragraphStyle] as! NSParagraphStyle
        #expect(code.lineSpacing > 0 && code.lineSpacing < p.lineSpacing)  // 104 % against 116 %
    }
}

@Suite @MainActor struct MarkdownCountTests {
    init() { _ = NSApplication.shared }  // AppKit text and scrolling need the application object

    // What QTextDocument.toPlainText gave for each, in Python (the typewriter's hidden count is in these characters).
    /// What Qt does with these is data loss or a placeholder, not behaviour to copy: an image is U+FFFC (here its alt text), and
    /// a `<br>` drops the rest of the document (here it is a line break).
    private static let different: Set<String> = ["![alt text](http://x/y.png)", "foo<br>bar"]

    @Test func theTextIsQtsOverTheWholeCorpus() {
        var bad: [String] = []
        for (source, qt) in qtCorpus where !Self.different.contains(source) {
            let got = md(source).string.replacingOccurrences(of: "\u{2028}", with: "\n")  // a hard break is one character either way
            if got != qt { bad.append("\(source.debugDescription): Qt \(qt.debugDescription), here \(got.debugDescription)") }
        }
        let report = "\(bad.count) differ:\n" + bad.joined(separator: "\n")
        #expect(bad.isEmpty, Comment(rawValue: report))
    }

    @Test(arguments: [
        ("a\nb", "a b"), ("a  \nb", "a\nb"), ("- a\n- b\n\n1. x\n2. y", "a\nb\nx\ny"), ("```\nl1\n\nl3\n```\n\nafter", "l1\n\nl3\nafter"),
        ("> quote\n\nafter", "quote\nafter"), ("# T\n\n## U", "T\nU"), ("1. a\n   - b\n2. c", "a\nb\nc"), ("one\n\ntwo", "one\ntwo"),
    ]) func theTextHasQtsCharacters(_ source: String, _ plain: String) {
        // a hard break is U+2028 here and shows as "\n" in Qt's toPlainText: one character either way
        let got = md(source).string
        #expect(got.replacingOccurrences(of: "\u{2028}", with: "\n") == plain)
        #expect(got.utf16.count == plain.utf16.count)
    }

    @Test func aRuleIsAnEmptyBlockThatCarriesTheLineToDraw() {
        let s = md("a\n\n---\n\nb")
        #expect(s.string == "a\n\nb")
        let rule = (s.string as NSString).range(of: "\n\n").location + 1  // the terminator of the empty block
        #expect((s.attribute(.rule, at: rule, effectiveRange: nil) as? NSColor).map(rgb) == hex(Themes.cyan.text))
        #expect(s.attribute(.rule, at: 1, effectiveRange: nil) == nil)
        #expect(md("a\n\n---").attribute(.ruleEnd, at: 1, effectiveRange: nil) != nil)  // a rule last has no character: the one before carries it
        #expect(md("---").string == "\n" && md("---\n\nafter").string == "\n\nafter")  // Qt keeps an empty block before a rule that starts the text
    }

    @Test func aRuleIsDrawnAcrossTheWidthInTheTextColour() {
        for source in ["intro\n\n---\n\nend", "intro\n\n---"] {
            let box = TextBox(width: 302)
            box.setContent(md(source))
            box.setBoxHeight(box.wantedHeight(cap: 300))
            let rep = box.bitmapImageRepForCachingDisplay(in: box.bounds)!
            box.cacheDisplay(in: box.bounds, to: rep)
            let want = Themes.rgba(Themes.cyan.text)
            var rows: [Int] = []
            for y in 0..<rep.pixelsHigh {
                let wide = (0..<rep.pixelsWide).filter { x in
                    let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                    return abs(Int(c.redComponent * 255) - Int(want.r)) < 6 && abs(Int(c.blueComponent * 255) - Int(want.b)) < 6 && c.alphaComponent > 0.9
                }.count
                if wide > rep.pixelsWide * 9 / 10 { rows.append(y) }
            }
            #expect(!rows.isEmpty && rows.count <= 2, "\(source.debugDescription): a line of the text colour across the box: rows \(rows)")
        }
    }

    @Test func aTaskIsABoxNotABulletWithBrackets() {
        let s = md("- [ ] todo\n- [x] done\n- [X] big\n- plain [ ] inside")
        #expect(s.string == "todo\ndone\nbig\nplain [ ] inside")
        #expect(["box", "checked", "checked", "disc"] == [0, 5, 10, 14].map { s.attribute(.listMarker, at: $0, effectiveRange: nil) as? String ?? "" })
        #expect(indent(blocks(s)[0].attrs) == 18)  // the box sits in the list's margin, like a bullet
    }

    @Test func aTaskBoxIsDrawnWithItsXWhenDone() {
        func ink(_ source: String) -> Int {
            let box = TextBox(width: 302)
            box.setContent(md(source))
            box.setBoxHeight(box.wantedHeight(cap: 300))
            let rep = box.bitmapImageRepForCachingDisplay(in: box.bounds)!
            box.cacheDisplay(in: box.bounds, to: rep)
            return (0..<rep.pixelsHigh).reduce(0) { n, y in n + (0..<18).filter { rep.colorAt(x: $0, y: y)!.alphaComponent > 0.3 }.count }  // the margin left of the text
        }
        let open = ink("- [ ] todo"), done = ink("- [x] done"), bullet = ink("- todo")
        #expect(open > 20 && done > open + 6)  // a frame, and the frame with a cross
        #expect(bullet > 0 && bullet != open)
    }

    @Test func rawHTMLIsReadNotShown() {
        let s = md("<b>x</b> text and <i>it</i> and <u>u</u> <span>s</span> and <a href=\"https://x.y\">l</a>")
        #expect(s.string == "x text and it and u s and l")
        #expect(bold(font(run(s, "x"))) && !bold(font(run(s, "text"))) && italic(font(run(s, "it"))))
        #expect(run(s, "u")[.underlineStyle] != nil && run(s, "s")[.underlineStyle] == nil)
        #expect((run(s, "l")[.link] as? URL)?.absoluteString == "https://x.y")
        #expect(md("<div>block</div>\n\nafter").string == "block\nafter")
        #expect(md("foo<br>bar").string == "foo\u{2028}bar")  // Qt drops "bar" and the rest of the text; a break is what it was meant to be
        #expect(md("1 < 2 and 3 > 2").string == "1 < 2 and 3 > 2" && md("x <!-- c --> y").string == "x  y")
    }

    @Test func aQuoteIsIndentedFortyOnBothSides() {
        let b = blocks(md("> quoted\n\nafter\n\n> - in a list"))
        #expect(indent(b[0].attrs) == 40 && (b[0].attrs[.paragraphStyle] as! NSParagraphStyle).tailIndent == -40)
        #expect(indent(b[1].attrs) == 0 && (b[1].attrs[.paragraphStyle] as! NSParagraphStyle).tailIndent == 0)
        #expect(indent(b[2].attrs) == 58)  // 40 and the list's 18
    }

    @Test func aBulletIsDrawnNotTypedSoTheCountIsQts() {
        let s = md("- a\n- b")
        #expect(s.string == "a\nb" && s.length == 3)
        #expect(s.attribute(.listMarker, at: 0, effectiveRange: nil) as? String == "disc")
        #expect(s.attribute(.listMarker, at: 2, effectiveRange: nil) as? String == "disc")
        #expect(s.attribute(.listMarker, at: 1, effectiveRange: nil) == nil)
    }

    @Test func numbersAndNestedBulletsKeepTheirKind() {
        let s = md("1. one\n2. two\n   - deep")
        #expect(s.attribute(.listMarker, at: 0, effectiveRange: nil) as? String == "1.")
        #expect(s.attribute(.listMarker, at: 4, effectiveRange: nil) as? String == "2.")
        #expect(run(s, "deep")[.listMarker] as? String == "circle")
    }

    @Test func theHiddenTailIsPaintedTransparentAndOnlyThat() {
        let s = md("Friday has the **lab report** due [now](https://x.y).", hidden: 12)
        let n = s.length
        for i in 0..<n {
            let a = s.attributes(at: i, effectiveRange: nil), clear = (a[.foregroundColor] as! NSColor).alphaComponent == 0
            #expect(clear == (i >= n - 12), "character \(i)")
            if i >= n - 12 { #expect(a[.link] == nil && a[.inlineBox] == nil) }
        }
        #expect(s.attribute(.link, at: (s.string as NSString).range(of: "now").location, effectiveRange: nil) != nil || (s.string as NSString).range(of: "now").location >= n - 12)
        #expect(md("abc", hidden: 99).length == 3 && (md("abc", hidden: 99).attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor).alphaComponent == 0)
        #expect((md("abc", hidden: 0).attribute(.foregroundColor, at: 2, effectiveRange: nil) as! NSColor).alphaComponent == 1)
    }

    @Test func theHiddenCountIsUTF16LikeQts() {
        let s = md("😀 hi", hidden: 2)  // "hi" is hidden; the emoji is two units
        #expect(s.length == 5)
        #expect((s.attribute(.foregroundColor, at: 2, effectiveRange: nil) as! NSColor).alphaComponent == 1)
        #expect((s.attribute(.foregroundColor, at: 3, effectiveRange: nil) as! NSColor).alphaComponent == 0)
    }

    @Test func aPrefixThatEndsInsideAMarkIsStillCleanText() {
        for prefix in ["", "**", "**bo", "- ", "## ", "`co", "[li", "[li](http", "```py\nx"] { _ = md(prefix) }  // none of these may crash or fail
        #expect(md("").length == 0)
        #expect(md("**bo").string == "**bo")  // an unclosed mark is text until it closes
    }
}

@Suite @MainActor struct TextSizingTests {
    init() { _ = NSApplication.shared }  // AppKit text and scrolling need the application object

    @Test func anEmptyBoxIsZeroAndATextBoxIsItsTextPlusTwoUpToTheCap() {
        let box = TextBox(width: 302)
        #expect(box.wantedHeight(cap: 300) == 0 && box.isBlank)
        box.setContent(md("Hello there"))
        let one = box.wantedHeight(cap: 300)
        #expect(one == CGFloat(Int(box.documentHeight)) + 2 && !box.overflows)
        box.setContent(md((0..<24).map { "Paragraph \($0) with a few words in it." }.joined(separator: "\n\n")))
        #expect(box.wantedHeight(cap: 300) == 300 && box.overflows)
        #expect(box.wantedHeight(cap: 100) == 100)
        box.setContent(NSAttributedString())
        #expect(box.wantedHeight(cap: 300) == 0 && !box.overflows && box.documentHeight == 0)
    }

    @Test func theTextWidthIsTheBoxWidthMinusTheScrollBarWhenItShows() {
        let box = TextBox(width: 291)
        box.setContent(md("short"))
        _ = box.wantedHeight(cap: 90)
        #expect(box.textView.frame.width == 291)
        box.setContent(md(String(repeating: "a long question that wraps ", count: 30)))
        #expect(box.wantedHeight(cap: 90) == 90 && box.textView.frame.width == 286)
    }

    @Test func theCursorRectIsOnTheLineOfTheCharacter() {
        let box = TextBox(width: 302)
        box.setContent(md(String(repeating: "word ", count: 200)))
        box.setBoxHeight(box.wantedHeight(cap: 300))
        let first = box.cursorRect(at: 0), later = box.cursorRect(at: 200), end = box.cursorRect(at: box.length)
        #expect(first.minX == 0 && first.minY == 0 && first.height > 14)
        #expect(later.minY > first.minY && end.minY >= later.minY)
        #expect(box.cursorRect(at: 5).minX > first.minX)
        box.scrollValue = 30
        #expect(box.cursorRect(at: 0).minY == -30)  // viewport coordinates
        #expect(TextBox(width: 302).cursorRect(at: 0).height > 0)  // an empty text still has a line
    }

    @Test func aLineWithAnEmojiIsNotTallerThanOneWithout() {
        for t in [Themes.cyan, Themes.matrix] {
            let plain = TextBox(width: 302), emoji = TextBox(width: 302)
            plain.setContent(md("In Obsidian: Plan", t)); emoji.setContent(md("📓 In Obsidian: Plan 📂", t))
            #expect(abs(plain.wantedHeight(cap: 300) - emoji.wantedHeight(cap: 300)) <= 1, "\(t.key)")
        }
    }

    @Test func plainTextIsOneFontAndColour() {
        let font = NSFont.systemFont(ofSize: 12), s = Markdown.plain("what's **due**?", font: font, colour: .red)
        #expect(s.string == "what's **due**?" && s.attribute(.font, at: 3, effectiveRange: nil) as? NSFont == font)
    }
}
