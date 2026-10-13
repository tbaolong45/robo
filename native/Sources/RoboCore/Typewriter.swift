// Typewriter reveal of Robo's reply. Port of src/robo/typewriter.py: pure, and the class never reads a clock.
//
// A reply is a Markdown string that grows while Hermes streams it. `Typewriter` decides how much of
// it is on screen at each moment; `markdownPrefix` turns "the first k characters" into a Markdown
// string that renders cleanly (no `**` or empty bullets flashing by).
//
// Python indexes code points, so everything here works on arrays of Unicode scalars, never on
// Characters (Swift's grapheme clusters would give other positions for emoji and combining marks).
//
// Schedule: every character gets a reveal time r[i] (seconds of "base pace"):
//   * visible characters cost 1/cps (code-block characters 1/(cps*codeSpeed));
//   * Markdown syntax costs nothing. An opening mark (`**`, a backtick, `[`, `- `, `## `, a ```fence
//     line) is revealed WITH the next visible character, a closing mark (`**`, `](url)`, the closing
//     fence) WITH the previous one, so a prefix never ends inside a mark;
//   * pauses (added before the NEXT character): after . ? ! and an ellipsis 0.20 s, after , ; :
//     0.07 s, after a newline 0.08 s, after a blank line 0.18 s; none inside code blocks.
// Playback: a position `played` (schedule seconds) moves at 1x, faster when Hermes is ahead of the
// reveal: speed = clamp(backlog / time constant, 1, cap). One rule, an exponential catch-up, so a
// long reply eases back to base pace instead of ending in a flash.
import Foundation

/// How fast and with which pauses a reply is typed.
public struct Pace: Equatable {
    public var cps: Double  // visible characters per second; 0 = instant
    public var sentence = 0.20  // extra seconds after . ? ! … (when followed by a break or a closer)
    public var clause = 0.07  // after , ; : followed by a space
    public var line = 0.08  // after a newline
    public var para = 0.18  // after a blank line
    public var codeSpeed = 2.2  // code blocks type this many times faster
    public var lag = 2.0  // time constant of the catch-up while Hermes streams (s)
    public var maxStream = 6.0  // speed cap while streaming (x base)
    public var finish = 1.0  // time constant once the run has ended (s)
    public var maxFinish = 8.0  // speed cap once the run has ended (x base)
    public var talkGap = 0.11  // s after a visible character the mouth keeps moving
    public init(cps: Double = 55) { self.cps = cps }
}

/// Feed it the text received so far; call `advance(dt)` from a ~30 Hz timer.
public final class Typewriter {
    public private(set) var pace: Pace
    public private(set) var clock = 0.0  // accumulated from advance(); the class never reads time
    public private(set) var text = ""
    public private(set) var k = 0  // code points of `text` shown (not Characters)
    public private(set) var ended = false, skipped = false
    private(set) var plans = 0  // how often the whole reply was re-planned (a tick must never)
    private var chars: [Unicode.Scalar] = []
    private var lastVis = -Double.infinity  // clock when a visible character last appeared
    private var played = 0.0, total = 0.0  // schedule seconds played / planned
    private var r: [Double] = []  // reveal time per character
    private var kind: [Kind] = []
    private var m = 0  // characters that have a finite reveal time

    public init(_ pace: Pace = Pace()) { self.pace = pace }

    /// A new exchange.
    public func reset() {
        text = ""; chars = []; k = 0
        ended = false; skipped = false
        lastVis = -.infinity
        played = 0; total = 0
        r = []; kind = []; m = 0
    }

    public var instant: Bool { skipped || pace.cps <= 0 }
    public var started: Bool { k > 0 }
    public var pending: Bool { k < chars.count }
    public var done: Bool { ended && !pending }
    /// Caught up with Hermes but the run goes on: the caret blinks.
    public var waiting: Bool { !ended && k >= m }
    /// A visible character appeared in the last `talkGap` s: the mouth moves.
    public var revealing: Bool { clock - lastVis <= pace.talkGap }
    public var fraction: Double { chars.isEmpty ? 1 : Double(k) / Double(chars.count) }

    /// ALL the reply received so far (not just the new chunk).
    public func feed(_ text: String) { plan(text) }

    /// The run is over; `text` is the final reply when it may differ from what streamed.
    public func end(_ text: String? = nil) {
        ended = true
        plan(text ?? self.text)
    }

    /// Click: show everything now, and everything that still arrives.
    public func skip() {
        skipped = true
        plan(text)
    }

    /// New speed (theme switch): re-plan and carry on from the character shown now.
    public func setPace(_ pace: Pace) {
        self.pace = pace
        plan(text, anchor: true)
    }

    private func plan(_ new: String, anchor: Bool = false) {
        var anchor = anchor
        let old = chars
        chars = Array(new.unicodeScalars)
        text = new
        plans += 1
        if !chars.starts(with: old) {  // not an extension: re-type from the first difference
            var common = 0
            while common < min(old.count, chars.count), old[common] == chars[common] { common += 1 }
            k = min(k, common)
            anchor = true
        }
        if instant {
            k = chars.count; m = chars.count
            r = []; kind = []; total = 0
            return
        }
        (r, kind, _) = Self.schedule(chars, pace, final: ended)
        m = firstIndex(in: r) { $0 >= .infinity }
        total = m > 0 ? r[m - 1] : 0
        if anchor {  // the schedule moved under us: play from the last character shown
            played = k > 0 ? min(total, r[k - 1]) : 0
        }
    }

    /// Move `dt` seconds on; true when more text is now visible.
    @discardableResult
    public func advance(_ dt: Double) -> Bool {
        clock += dt
        if k >= m { return false }
        let backlog = total - played
        let speed = ended ? min(pace.maxFinish, max(1, backlog / pace.finish))
                          : min(pace.maxStream, max(1, backlog / pace.lag))
        played = min(total, played + dt * speed)
        let next = firstIndex(in: r) { $0 > played }
        if next <= k { return false }
        if kind[k..<next].contains(.visible) { lastVis = clock }
        k = next
        return true
    }

    /// The Markdown to render now and the UTF-16 units at its end that are laid out but painted
    /// transparent. The finished reply is returned as is.
    public func view() -> (markdown: String, hidden: Int) {
        if done || pace.cps <= 0 { return (text, 0) }
        return Self.markdownPrefix(chars, kind, k)
    }
}

/// First index whose element satisfies `isPast`, in an array where that is false and then true:
/// Python's `bisect`.
private func firstIndex(in r: [Double], where isPast: (Double) -> Bool) -> Int {
    var lo = 0, hi = r.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if isPast(r[mid]) { hi = mid } else { lo = mid + 1 }
    }
    return lo
}

// MARK: - Classifying characters

extension Typewriter {
    enum Kind { case visible, opening, closing }

    /// Inline Markdown marks. `*` alone is italic; `_` alone is not a mark.
    enum Mark: String { case bold = "**", under = "__", strike = "~~", tick = "`", star = "*" }

    static let wordMax = 16  // characters of the current word that are laid out in advance (hidden)
    private static let partial = Set("*_~`#>+-".unicodeScalars)  // could be the first half of a Markdown mark
    private static let stops = Set(".?!\u{2026}".unicodeScalars)
    private static let closers = Set("\"')*_".unicodeScalars)
    private static let clauses = Set(",;:".unicodeScalars)

    /// (kind, in_code) per character of `text`.
    static func classify(_ text: [Unicode.Scalar]) -> (kind: [Kind], code: [Bool]) {
        let n = text.count
        var kind = [Kind](repeating: .visible, count: n), code = [Bool](repeating: false, count: n)
        var pos = 0
        var fence: (ch: Unicode.Scalar, len: Int)?
        for piece in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = Array(piece)
            let end = pos + line.count + 1  // the line and its newline (the last line has none)
            let span = pos..<min(end, n)
            let m = fenceRun(line)
            var closes = false
            if let f = fence, let m {
                closes = m.ch == f.ch && m.len >= f.len && line.allSatisfy { $0 == " " || $0 == "`" || $0 == "~" }
            }
            if (m != nil && fence == nil) || closes {
                fence = fence == nil ? m : nil
                for i in span { kind[i] = fence != nil ? .opening : .closing; code[i] = true }
            } else if fence != nil {
                for i in span { code[i] = true }
            } else {
                let start = blockMarkEnd(line)
                for i in pos..<pos + start { kind[i] = .opening }
                var taken = [Bool](repeating: false, count: line.count)  // characters already claimed by a link
                for link in links(line) {
                    kind[pos + link.a] = .opening
                    taken[link.a] = true
                    if let close = link.close {
                        for j in close..<link.z { kind[pos + j] = .closing; taken[j] = true }
                    }
                }
                var state: [Mark: Bool] = [:]
                for (a, mark) in inlineMarks(line, from: start) where !taken[a] {
                    if state[.tick] == true && mark != .tick { continue }  // literal inside a code span
                    let open = !(state[mark] ?? false)
                    state[mark] = open
                    for j in a..<a + mark.rawValue.count { kind[pos + j] = open ? .opening : .closing }
                }
            }
            pos = end
        }
        return (kind, code)
    }

    /// Marks, skin tones, ZWJ, what follows a ZWJ and the 2nd half of a flag ride with the previous
    /// character. `ri` = length of the run of regional indicators that ends with `ch`.
    private static func glue(_ ch: Unicode.Scalar, _ prev: Unicode.Scalar?, _ ri: Int) -> Bool {
        switch ch.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format, .modifierSymbol: return true
        default: return prev == "\u{200D}" || (isRegional(ch) && ri % 2 == 0)
        }
    }

    private static func isRegional(_ ch: Unicode.Scalar) -> Bool { (0x1F1E6...0x1F1FF).contains(ch.value) }

    /// (reveal time, kind, in_code) per character. Times never decrease; `.infinity` = not before
    /// more text arrives. Needs pace.cps > 0 (Typewriter handles 0 itself).
    static func schedule(_ text: [Unicode.Scalar], _ pace: Pace, final: Bool)
        -> (r: [Double], kind: [Kind], code: [Bool]) {
        let planned = classify(text)
        var kind = planned.kind
        let code = planned.code, n = text.count
        if !final {  // the other half of a mark may still be on its way: `-` of `- `, `*` of `**`
            var i = n
            while i > 0, partial.contains(text[i - 1]), kind[i - 1] == .visible {
                i -= 1
                kind[i] = .opening
            }
        }
        var r = [Double](repeating: 0, count: n)
        var t = 0.0, carry = 0.0, ri = 0
        var prev: Unicode.Scalar?
        for i in 0..<n where kind[i] == .visible {
            let ch = text[i]
            ri = isRegional(ch) ? ri + 1 : 0
            var step = 1.0 / pace.cps / (code[i] ? pace.codeSpeed : 1.0)
            if glue(ch, prev, ri) { step = 0 }
            t += step + carry
            r[i] = t
            let nxt: Unicode.Scalar = i + 1 < n ? text[i + 1] : " "  // the stream's end counts as a break
            carry = 0
            if code[i] {
                carry = ch == "\n" ? 0.03 : 0
            } else if ch == "\n" {
                carry = nxt == "\n" ? 0 : (prev == "\n" ? pace.para : pace.line)
            } else if stops.contains(ch) && (nxt.isPySpace || closers.contains(nxt)) {
                carry = pace.sentence
            } else if clauses.contains(ch) && nxt.isPySpace {
                carry = pace.clause
            }
            prev = ch
        }
        var ahead = Double.infinity  // opening marks wait for the next visible character
        for i in stride(from: n - 1, through: 0, by: -1) {
            if kind[i] == .visible { ahead = r[i] } else if kind[i] == .opening { r[i] = ahead }
        }
        var back = 0.0  // closing marks go with the previous visible character
        for i in 0..<n {
            if kind[i] == .visible { back = r[i] } else if kind[i] == .closing { r[i] = back }
        }
        var top = 0.0
        for i in 0..<n {  // keep it non-decreasing (adjacent closing + opening marks)
            top = max(top, r[i])
            r[i] = top
        }
        if final {  // nothing more will come: marks that waited are revealed at the end
            let m = firstIndex(in: r) { $0 >= .infinity }
            let last = m > 0 ? r[m - 1] : 0
            for i in m..<n { r[i] = last }
        }
        return (r, kind, code)
    }
}

// The line scanners below replace Python's regexes. They are written for code points, as `re` is.

/// A code-fence line: up to 3 spaces, then a run of 3 or more backticks or tildes.
private func fenceRun(_ line: [Unicode.Scalar]) -> (ch: Unicode.Scalar, len: Int)? {
    var i = 0
    while i < 3, i < line.count, line[i] == " " { i += 1 }
    guard i < line.count, line[i] == "`" || line[i] == "~" else { return nil }
    let ch = line[i]
    var j = i
    while j < line.count, line[j] == ch { j += 1 }
    return j - i >= 3 ? (ch, j - i) : nil
}

/// Length of the block marks that open a line, nested or not (`## `, `> `, `- `, `1. `); 0 if none.
private func blockMarkEnd(_ line: [Unicode.Scalar]) -> Int {
    let n = line.count
    func blank(_ i: Int) -> Bool { i < n && (line[i] == " " || line[i] == "\t") }
    var end = 0
    while true {
        var i = end, spaces = 0
        while spaces < 3, i < n, line[i] == " " { i += 1; spaces += 1 }
        guard i < n else { return end }
        var j = i
        switch line[i] {
        case "#":
            while j < n, line[j] == "#" { j += 1 }
            guard j - i <= 6, blank(j) else { return end }
            while blank(j) { j += 1 }
        case ">":
            j += 1
            if blank(j) { j += 1 }
        case "-", "*", "+":
            j += 1
            guard blank(j) else { return end }
            while blank(j) { j += 1 }
        default:  // 1 to 9 digits (any script, as `\d`), then . or ), then spaces
            while j < n, line[j].properties.generalCategory == .decimalNumber { j += 1 }
            guard (1...9).contains(j - i), j < n, line[j] == "." || line[j] == ")", blank(j + 1) else { return end }
            j += 1
            while blank(j) { j += 1 }
        }
        end = j
    }
}

/// `[text](url)` and its unfinished forms `[text](url` and `[text`: start, end and the `](` position.
private func links(_ line: [Unicode.Scalar]) -> [(a: Int, z: Int, close: Int?)] {
    var out: [(a: Int, z: Int, close: Int?)] = []
    var i = 0
    while i < line.count {
        guard line[i] == "[" else { i += 1; continue }
        var j = i + 1
        while j < line.count, line[j] != "]" { j += 1 }
        if j == line.count {
            out.append((i, j, nil))
            break
        }
        guard j + 1 < line.count, line[j + 1] == "(" else { i += 1; continue }
        var z = j + 2
        while z < line.count, line[z] != ")" { z += 1 }
        if z < line.count { z += 1 }
        out.append((i, z, j))
        i = z
    }
    return out
}

/// The inline marks of `line` from `start` on, left to right and not overlapping. A `*` is a mark
/// when a non-space follows it or a non-space, non-`*` precedes it (the look-behind may see
/// characters before `start`, as in Python).
private func inlineMarks(_ s: [Unicode.Scalar], from start: Int) -> [(at: Int, mark: Typewriter.Mark)] {
    var out: [(at: Int, mark: Typewriter.Mark)] = []
    var i = start
    while i < s.count {
        let next: Unicode.Scalar? = i + 1 < s.count ? s[i + 1] : nil
        var mark: Typewriter.Mark?
        switch s[i] {
        case "*":
            if next == "*" { mark = .bold }
            else if let c = next, !c.isPySpace { mark = .star }
            else if i > 0, !s[i - 1].isPySpace, s[i - 1] != "*" { mark = .star }
        case "_": if next == "_" { mark = .under }
        case "~": if next == "~" { mark = .strike }
        case "`": mark = .tick
        default: break
        }
        if let mark {
            out.append((i, mark))
            i += mark.rawValue.count
        } else {
            i += 1
        }
    }
    return out
}

// MARK: - Markdown of a prefix

extension Typewriter {
    /// Delimiters that make the unfinished last line of `prefix` well-formed.
    private static func closing(_ prefix: [Unicode.Scalar]) -> String {
        let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.filter({ fenceRun(Array($0)) != nil }).count % 2 == 1 {
            return ""  // inside a code block: the importer closes it at the end
        }
        let line = Array(lines[lines.count - 1])
        var stack: [Mark] = []
        for (_, mark) in inlineMarks(line, from: 0) {
            if stack.contains(.tick) && mark != .tick { continue }
            if let i = stack.firstIndex(of: mark) { stack.removeSubrange(i...) } else { stack.append(mark) }
        }
        var out = stack.reversed().map(\.rawValue).joined()
        let lastParen = line.lastIndex(of: ")") ?? -1
        if let open = line.lastIndex(of: "["), open > (line.lastIndex(of: "]") ?? -1) {  // `[text` with no `]` yet
            out = stack.isEmpty ? "](#)" : out + "](#)"
        } else if let url = line.indices.last(where: { $0 + 1 < line.count && line[$0] == "]" && line[$0 + 1] == "(" }),
                  url > lastParen {  // `](url` with no `)` yet
            out = ")" + out
        }
        return out
    }

    /// (markdown, hidden): `text[..<k]` made renderable. The renderer lays out `hidden` more UTF-16
    /// units (the rest of the current word) and paints them transparent, so a word that will not fit
    /// the line wraps when its first letter appears, not when its last one does.
    static func markdownPrefix(_ text: [Unicode.Scalar], _ kind: [Kind], _ k: Int) -> (markdown: String, hidden: Int) {
        var i = k
        while i < text.count, i - k < wordMax, kind[i] == .visible, !text[i].isPySpace { i += 1 }
        let body = Array(text[..<i])
        let close = closing(body)
        var cut = body.count
        if !close.isEmpty {  // `**bo **` is not a closed bold
            while cut > 0, body[cut - 1] == " " || body[cut - 1] == "\t" { cut -= 1 }
        }
        let md = body[..<cut] + close.unicodeScalars + body[cut...]
        let hidden = text[k..<i].reduce(0) { $0 + ($1.value > 0xFFFF ? 2 : 1) }  // UTF-16 units
        return (String(String.UnicodeScalarView(md)), hidden)
    }
}
