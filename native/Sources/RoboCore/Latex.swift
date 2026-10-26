// LaTeX in a reply: `$x^2$` and `\(x^2\)` (inline), `$$ ... $$` and `\[ ... \]` (display). A Markdown parser would eat the backslashes of
// `\frac`, `\_` and `\{`, so the formulas are taken out BEFORE the text is parsed: each becomes a placeholder (a private-use character, its
// number, another one) that survives the parser, and the window typesets the formula and puts it back (RoboUI/Math.swift). Pure: strings in,
// strings out. What is not clearly a formula stays text: code (fenced or inline) is never read, `\$` is a dollar sign, and an inline `$`
// opens a formula only the way pandoc reads it (no space after the opening one, none before the closing one, and a digit after it means
// money: "it costs $5 and $10" has no formula).
import Foundation

public enum Latex {
    public struct Span: Equatable, Sendable {
        public let source: String
        public let display: Bool
        public init(source: String, display: Bool) { (self.source, self.display) = (source, display) }
    }

    public static let open: Character = "\u{E000}", close: Character = "\u{E001}"
    public static let maxSpans = 60, maxLength = 600

    /// The text with every formula replaced by its placeholder, and the formulas in order.
    public static func extract(_ markdown: String) -> (text: String, spans: [Span]) {
        guard markdown.contains("$") || markdown.contains("\\(") || markdown.contains("\\[") else { return (markdown, []) }
        let c = Array(markdown)
        var out = "", spans: [Span] = []
        var i = 0
        var lineStart = true
        /// Make the formula a placeholder; false (and nothing done) when it holds nothing but white space.
        @discardableResult func put(_ source: String, display: Bool) -> Bool {
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            out.append(open)
            out += String(spans.count)
            out.append(close)
            spans.append(Span(source: source.trimmingCharacters(in: .whitespacesAndNewlines), display: display))
            return true
        }
        func find(_ token: [Character], from: Int, sameLine: Bool, stopAtBlank: Bool) -> Int? {
            var j = from
            while j + token.count <= c.count {
                if c[j] == "\n" && (sameLine || (stopAtBlank && j + 1 < c.count && c[j + 1] == "\n")) { return nil }
                if Array(c[j..<(j + token.count)]) == token && (j == from || c[j - 1] != "\\") { return j }
                j += 1
            }
            return nil
        }
        while i < c.count {
            let ch = c[i]
            // a fenced code block: a line that starts with ``` or ~~~ up to the next such line is code
            if lineStart, ch == "`" || ch == "~", i + 2 < c.count, c[i + 1] == ch, c[i + 2] == ch {
                var j = i
                while j < c.count, c[j] != "\n" { j += 1 }  // the fence line
                while j < c.count {
                    let next = j + 1
                    if next + 2 < c.count, c[next] == ch, c[next + 1] == ch, c[next + 2] == ch {
                        j = next
                        while j < c.count, c[j] != "\n" { j += 1 }
                        break
                    }
                    j += 1
                    while j < c.count, c[j] != "\n" { j += 1 }
                }
                out += String(c[i..<min(j, c.count)])
                i = min(j, c.count)
                lineStart = false
                continue
            }
            lineStart = ch == "\n"
            // inline code: a run of backticks to the next run of the same length
            if ch == "`" {
                var n = 0
                while i + n < c.count, c[i + n] == "`" { n += 1 }
                var j = i + n, end: Int?
                while j < c.count {
                    if c[j] == "`" {
                        var m = 0
                        while j + m < c.count, c[j + m] == "`" { m += 1 }
                        if m == n { end = j + m; break }
                        j += m
                    } else {
                        j += 1
                    }
                }
                let stop = end ?? (i + n)
                out += String(c[i..<stop])
                i = stop
                continue
            }
            if ch == "\\", i + 1 < c.count {
                let n = c[i + 1]
                if spans.count < maxSpans, n == "(" || n == "[" {
                    let token: [Character] = ["\\", n == "(" ? ")" : "]"]
                    if let end = find(token, from: i + 2, sameLine: false, stopAtBlank: true), end - i - 2 > 0, end - i <= maxLength,
                       put(String(c[(i + 2)..<end]), display: n == "[") {
                        i = end + 2
                        continue
                    }
                }
                out += String(c[i...(i + 1)])  // an escape: `\$`, `\\`, `\_`... stays as it is (the Markdown parser reads it)
                i += 2
                continue
            }
            if ch == "$", spans.count < maxSpans {
                if i + 1 < c.count, c[i + 1] == "$" {
                    if let end = find(["$", "$"], from: i + 2, sameLine: false, stopAtBlank: true), end - i - 2 > 0, end - i <= maxLength,
                       put(String(c[(i + 2)..<end]), display: true) {
                        i = end + 2
                        continue
                    }
                } else if i + 1 < c.count, !c[i + 1].isWhitespace {
                    // the first unescaped `$` decides: it closes the formula if it may (no space before it, no digit after it), else
                    // this opener is just a dollar sign (a formula holds no bare `$`)
                    var j = i + 1
                    while j < c.count, c[j] != "\n", c[j] != "`", !(c[j] == "$" && c[j - 1] != "\\") { j += 1 }  // code ends the search too
                    if j < c.count, c[j] == "$", !c[j - 1].isWhitespace, !(j + 1 < c.count && c[j + 1].isNumber), j - i - 1 > 0,
                       j - i <= maxLength, put(String(c[(i + 1)..<j]), display: false) {
                        i = j + 1
                        continue
                    }
                }
            }
            out.append(ch)
            i += 1
        }
        return (out, spans)
    }

    /// The placeholders in `text`: where each is (UTF-16 range) and the number of its formula.
    public static func placeholders(in text: String) -> [(range: NSRange, index: Int)] {
        let ns = text as NSString
        var found: [(NSRange, Int)] = []
        let opening = open.utf16.first!, closing = close.utf16.first!
        var i = 0
        while i < ns.length {
            if ns.character(at: i) == opening {
                var j = i + 1
                var digits = ""
                while j < ns.length, let u = Unicode.Scalar(ns.character(at: j)), u.properties.numericType == .decimal {
                    digits.unicodeScalars.append(u)
                    j += 1
                }
                if j < ns.length, ns.character(at: j) == closing, let n = Int(digits) {
                    found.append((NSRange(location: i, length: j - i + 1), n))
                    i = j
                }
            }
            i += 1
        }
        return found
    }
}
