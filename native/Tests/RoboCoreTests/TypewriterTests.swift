// Port of tests/test_typewriter.py, plus golden parity with the Python typewriter.
//
// The typewriter is pure (no clock): tests drive it with dt, like the 33 ms timer does. The Python
// tests render a revealed prefix with Qt to see stray Markdown syntax; here Foundation's Markdown
// parser does, the one a Swift UI will use.
//
// Goldens: produced by running src/robo/typewriter.py (commit dc8c8ee, Python 3.14, Unicode 16) with
// the driver `Rec` below mirrored in Python. A trace is the list of (tick, k, pending, hidden,
// markdown) printed whenever one of the last four changes, and a line per tick of
//   tick|advance()|k|pending|hidden|revealing waiting done started|fraction bits|markdown
// whose SHA-256 (first 16 hex digits) is compared for every scenario. Small scenarios also embed the
// full trace so a failure shows where. Swift's String == is canonical equivalence (e + U+0301 equals
// U+00E9), Python's is code points, so every markdown comparison here is on scalars.
import CryptoKit
import Foundation
import Testing
@testable import RoboCore

private let dt = 1.0 / 30
private let step = 1.0 / 55  // seconds per visible character at the default pace

private let sample0: String = "Hi! Here is **today**: two things are due.\n\n"
    + "- **Linear Algebra** quiz at *10:00*, room `B-204`\n"
    + "- Essay draft for [History](https://moodle.example.edu/x)\n"
    + "- Lab report (due Friday)\n\n"
    + "Run this to check:\n\n```python\nprint('ok')\nfor i in range(3):\n    print(i)\n```\n\n"
    + "Good luck... you've got this!"
private let sample1: String = "## Week plan\n\n"
    + "1. **Monday**: finish the `lab` report, then read [chapter 3](https://x.example/c3)\n"
    + "2. *Tuesday*: quiz at **10:00** in room B-204\n"
    + "3. Wednesday is free\n\n"
    + "> Remember: **draft first**, polish later.\n\n"
    + "### Notes\n\n"
    + "- Bring the **calculator** and a `pen`\n"
    + "- Ping Sam about the group task\n\n"
    + "~~~text\nline one\nline two\n~~~\n\nDone! \u{1F44D}\u{1F3FD}"
private let samples = [sample0, sample1]

private func scalars(_ s: String) -> [Unicode.Scalar] { Array(s.unicodeScalars) }
private func len(_ s: String) -> Int { s.unicodeScalars.count }

/// Python's `text[:n]`.
private func head(_ s: String, _ n: Int) -> String { String(String.UnicodeScalarView(s.unicodeScalars.prefix(n))) }

/// Where `sub` starts in `text`, in code points (Python's `text.index(sub)`).
private func offset(of sub: String, in text: String) -> Int {
    len(String(text[..<text.range(of: sub)!.lowerBound]))
}

/// n characters of plain text with a sentence end and a clause break every dozen words.
private func prose(_ n: Int) -> String {
    head(String(repeating: "the quick brown fox jumps over a lazy dog, and then plans the week. ", count: n / 60 + 1), n)
}

/// pytest.approx: relative 1e-6, or `abs`.
private func near(_ a: Double, _ b: Double, abs tol: Double = 0) -> Bool {
    Swift.abs(a - b) <= max(1e-6 * Swift.abs(b), tol, 1e-12)
}

/// Tick at 30 Hz until the reply is done; the seconds that took.
@discardableResult
private func play(_ tw: Typewriter, limit: Double = 60) -> Double {
    var t = 0.0
    while !tw.done && t < limit {
        tw.advance(dt)
        t += dt
    }
    return t
}

private func ticks(_ tw: Typewriter, _ n: Int) {
    for _ in 0..<n { tw.advance(dt) }
}

/// Hermes delivered everything in one go and the run is over.
private func atOnce(_ text: String) -> Typewriter {
    let tw = Typewriter()
    tw.feed(text)
    tw.end()
    return tw
}

/// Seconds between the reveal of text[i] and text[i + 1] at the default pace.
private func gap(_ text: String, _ i: Int) -> Double {
    let r = Typewriter.schedule(scalars(text), Pace(), final: true).r
    return r[i + 1] - r[i]
}

/// Hermes sends `chunk` characters at a time at `cps`; the window ticks at 30 Hz.
/// -> (seconds until done, seconds after the run ended, most characters held back)
private func stream(_ text: String, cps: Double, chunk: Int = 24) -> (t: Double, ended: Double, lag: Int) {
    let tw = Typewriter()
    var t = 0.0, got = 0, lag = 0
    var endedAt: Double?
    while !tw.done && t < 60 {
        while got < len(text) && Double(got) / cps <= t {
            got = min(len(text), got + chunk)
            tw.feed(head(text, got))
        }
        if got == len(text) && endedAt == nil {
            tw.end()
            endedAt = t
        }
        tw.advance(dt)
        t += dt
        #expect(tw.k <= got)  // never ahead of what was received
        lag = max(lag, got - tw.k)
    }
    return (t, t - (endedAt ?? 0), lag)
}

/// What a reader would see of `md` that is Markdown syntax, or nil. The Foundation parser drops an
/// empty bullet or heading instead of showing it, so those are looked for in the Markdown itself.
/// A number and its dot before the space has arrived (`1.`) is plain text, as in Python: only digits
/// are not among the characters that wait for their other half.
private func strayMarkdown(_ md: String) -> String? {
    guard let doc = try? AttributedString(markdown: md, options: .init(interpretedSyntax: .full)) else {
        return "does not parse"
    }
    var blocks: [Int: String] = [:]
    for run in doc.runs {
        let block = run.presentationIntent?.components.first?.identity ?? 0
        blocks[block, default: ""] += String(doc[run.range].characters)
    }
    if let text = blocks.values.first(where: { $0.contains("**") || $0.contains("`") || $0.contains("](") }) {
        return text
    }
    let bare = try! Regex(#" {0,3}(?:[-*+]|\d{1,9}[.)][ \t]|#{1,6})[ \t]*"#)
    var fenced = false
    for line in md.split(separator: "\n", omittingEmptySubsequences: false) {
        let open = line.drop { $0 == " " }
        if open.hasPrefix("```") || open.hasPrefix("~~~") { fenced.toggle() }
        if !fenced && line.wholeMatch(of: bare) != nil { return "empty bullet or bare #: \(line)" }
    }
    return nil
}

// MARK: - Markdown while typing

@Test(arguments: [0, 1])
func noReachablePrefixShowsMarkdownSyntax(i: Int) {
    let text = scalars(samples[i])
    let (r, kind, _) = Typewriter.schedule(text, Pace(), final: true)
    var reachable = Set<Int>()  // every k a player can stop at
    for t in r { reachable.insert(r.firstIndex { $0 > t } ?? r.count) }
    for k in reachable.sorted() {
        let (md, hidden) = Typewriter.markdownPrefix(text, kind, k)
        #expect(0...2 * Typewriter.wordMax ~= hidden)  // UTF-16 units
        #expect(strayMarkdown(md) == nil, "k=\(k) \(md.debugDescription)")
    }
}

/// Hermes may split a mark across deltas (`-` | ` item`, `*` | `*bold`) and stall in between.
@Test(arguments: [0, 1], [(1, 1), (1, 6), (3, 9)])
func aStreamCutAnywhereNeverShowsSyntax(i: Int, cut: (chunk: Int, every: Int)) {
    let sample = samples[i], total = len(sample)
    let tw = Typewriter()
    var got = 0, tick = 0
    var seen = Set<[Int]>()
    while !tw.done && tick < 20000 {
        if got < total && tick % cut.every == 0 {
            got = min(total, got + cut.chunk)
            tw.feed(head(sample, got))
            if got == total { tw.end() }
        }
        tw.advance(dt)
        tick += 1
        if seen.insert([tw.k, got]).inserted {
            let md = tw.view().markdown
            #expect(strayMarkdown(md) == nil, "k=\(tw.k) \(md.debugDescription)")
        }
    }
    let (md, hidden) = tw.view()
    #expect(md.unicodeScalars.elementsEqual(sample.unicodeScalars) && hidden == 0)
}

@Test func marksCostNoTimeAndRideWithANeighbour() {
    let r = Typewriter.schedule(scalars("**hi**"), Pace(), final: true).r
    #expect(r[0] == r[1] && r[1] == r[2])  // the opening ** comes with the h
    #expect(r[3] == r[4] && r[4] == r[5])  // the closing ** goes with the i
    let (kind, code) = Typewriter.classify(scalars("a\n```py\nx = 1\n```\nb"))
    let fence = kind.firstIndex(of: .opening)!
    #expect(code[fence] && !code[0] && !code[code.count - 1])  // the fence line is code
}

@Test func unfinishedMarksGetClosersAndTheRestOfTheWordIsHidden() {
    let text = "Hello **world** and see [the docs](http://x.io) now"
    let kind = Typewriter.classify(scalars(text)).kind
    let a = Typewriter.markdownPrefix(scalars(text), kind, len("Hello **wo"))
    #expect(a.markdown == "Hello **world**" && a.hidden == 3)
    let b = Typewriter.markdownPrefix(scalars(text), kind, len("Hello **world** and see [the"))
    #expect(b.markdown.hasSuffix("[the](#)"))
    let emoji = "a \u{1F44D}\u{1F3FD} bc"  // hidden counts UTF-16 units, as QTextCursor does
    #expect(Typewriter.markdownPrefix(scalars(emoji), Typewriter.classify(scalars(emoji)).kind, 2).hidden == 4)
}

@Test func aCloserNeverFollowsASpace() {
    let tw = Typewriter()
    tw.feed("**bo ")  // the delta ended on the space
    ticks(tw, 30)
    let (md, hidden) = tw.view()
    #expect(tw.waiting && md == "**bo** " && hidden == 0)
}

@Test func aHalfReceivedMarkWaitsForItsOtherHalf() {
    let tw = Typewriter()
    tw.feed("Items:\n\n-")
    ticks(tw, 90)
    #expect(tw.waiting && tw.pending && !tw.view().markdown.contains("-"))  // no empty bullet while it waits
    tw.feed("Items:\n\n- one")
    ticks(tw, 30)
    #expect(tw.view().markdown == "Items:\n\n- one")
    let dash = Typewriter()
    dash.feed("pick one -")
    dash.end()  // a dash that really is the last character is shown once the run is over
    let seconds = play(dash)
    #expect(seconds < 2 && dash.view().markdown == "pick one -" && dash.view().hidden == 0)
}

// MARK: - emoji

/// (name, text, offsets inside it where a cut is fine: between two flags)
private let clusters: [(String, String, [Int])] = [
    ("thumbs up with a skin tone", "\u{1F44D}\u{1F3FD}", []),
    ("two flags", "\u{1F1F3}\u{1F1F1}\u{1F1E9}\u{1F1EA}", [2]),
    ("family with ZWJ", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", []),
    ("keycap", "1\u{FE0F}\u{20E3}", []),
    ("e and a combining accent", "e\u{301}", []),
]

@Test(arguments: clusters.map(\.0))
func anEmojiClusterIsOneStepAndIsNeverCut(name: String) {
    let (_, cluster, cuts) = clusters.first { $0.0 == name }!
    let text = "a" + cluster + "b"
    let r = Typewriter.schedule(scalars(text), Pace(), final: true).r
    #expect(Set(r).count == cuts.count + 3)  // a, the cluster's steps, b
    let stops = Set(r.map { t in r.firstIndex { $0 > t } ?? r.count })
    #expect(stops == Set([1, 1 + len(cluster), len(text)] + cuts.map { 1 + $0 }))
}

// MARK: - timing

@Test func plainCharactersTakeTwoSeconds() {
    let plain = String(repeating: "abcdefghij ", count: 10)  // 110 of them
    let end = Typewriter.schedule(scalars(plain), Pace(), final: true).r.last!
    #expect(near(end, Double(len(plain)) / 55, abs: 0.05))
    let tw = Typewriter()
    tw.feed(plain)  // the run goes on: backlog / lag is exactly 1, so the base pace
    ticks(tw, 30)
    #expect((50...60).contains(tw.k))  // one second in
    ticks(tw, 36)
    #expect(tw.k == len(plain))
}

@Test func aSentenceEndPausesButDecimalsAndVersionsDoNot() {
    #expect(near(gap("Hi. Yo", 2), step + 0.20))
    #expect(near(gap("so... ok", 4), step + 0.20))  // only the last dot of an ellipsis
    #expect(near(gap("so... ok", 2), step))
    #expect(near(gap("pi is 3.14 ok", 7), step))
    #expect(near(gap("see v1.2 now", 6), step))
    #expect(near(gap("a, b", 1), step + 0.07))
    #expect(near(gap("a\nb", 1), step + 0.08))
    #expect(near(gap("a\n\nb", 2), step + 0.18))
}

@Test func codeTypes2_2TimesFasterWithNoSentencePause() {
    let text = "x\n\n```\nab. cd\nef\n```"
    let plain = gap("ab cd", 0)
    #expect(near(plain, step))
    #expect(near(gap(text, offset(of: "ab", in: text)), plain / 2.2))
    #expect(near(gap(text, offset(of: ".", in: text)), plain / 2.2))  // no pause after the dot
    let newline = offset(of: "cd", in: text) + 2  // a code newline adds 0.03 s
    #expect(near(gap(text, newline), plain / 2.2 + 0.03))
}

@Test func aWholeReplyThatArrivesAtOnceIsTypedNeverPopped() {
    let tw = atOnce(prose(40))
    tw.advance(dt)
    #expect(0 < tw.k && tw.k < 10 && tw.pending)
    #expect(play(atOnce(prose(11))) < 0.5)
    #expect(play(atOnce(prose(40))) < 1.5)
    #expect(play(atOnce(prose(120))) < 2.6)
    #expect(play(atOnce(prose(400))) < 3.7)
    #expect(play(atOnce(prose(1200))) < 6.5)
    #expect(play(atOnce(prose(3000))) < 12.5)  // a click skips it long before
}

@Test func aStreamedReplyTrailsHermesByAboutTwoSecondsAndFinishesFast() {
    for (n, cps, total, after) in [(300, 250.0, 4.5, 3.3), (600, 120.0, 8.6, 3.3), (1200, 250.0, 9.2, 4.1)] {
        let (t, ended, lag) = stream(prose(n), cps: cps)
        #expect(t < total && ended < after, "\(n) \(cps) \(t) \(ended)")
        #expect(Double(lag) / cps < 2.6, "\(n) \(cps) \(lag)")
    }
}

@Test func aStreamSlowerThanTheTypewriterIsTypedAsItArrives() {
    let (_, ended, lag) = stream(prose(600), cps: 30, chunk: 3)
    #expect(lag < 40 && ended < 1.0)
    let tw = Typewriter()
    tw.feed("Hello there")
    ticks(tw, 60)
    #expect(tw.k == 11 && tw.waiting && !tw.done)  // caught up: the caret blinks, nothing else
}

@Test func doneNeedsTheEndOfTheRun() {
    let tw = Typewriter()
    tw.feed("hi")
    ticks(tw, 30)
    #expect(tw.started && !tw.pending && tw.waiting && !tw.done && tw.fraction == 1)
    tw.end()
    #expect(tw.done && !tw.waiting)
}

@Test func theFinishedReplyIsRenderedExactlyAsReceived() {
    let tw = Typewriter()
    tw.feed("2*3 is six")  // a lone * looks like an open italic while streaming
    tw.end()
    let seconds = play(tw)
    #expect(seconds < 1 && tw.view().markdown == "2*3 is six" && tw.view().hidden == 0)
}

@Test func skipShowsWhatIsThereAndWhateverArrivesNext() {
    let tw = Typewriter()
    tw.feed("abc def")
    tw.skip()
    #expect(tw.k == 7 && !tw.pending)
    tw.feed("abc def ghi")
    #expect(tw.k == 11 && tw.view().markdown == "abc def ghi" && tw.view().hidden == 0)
    let moved = tw.advance(dt)
    #expect(!moved && !tw.done)
    tw.end("abc def ghi.")
    #expect(tw.done && tw.k == 12)
    let open = Typewriter()
    open.feed("**bo")
    open.skip()
    #expect(open.view().markdown == "**bo**" && open.view().hidden == 0)  // still streaming: the closer stays
}

@Test func aFinalTextThatDiffersIsRetypedFromTheFirstDifference() {
    let tw = Typewriter()
    tw.feed("Hello wonderful world, how are you today my friend")
    ticks(tw, 10)
    let shown = tw.k
    #expect(15 < shown && shown < 25)
    tw.end("Hello wonderful world, how are you today my friend, and more")  // an extension
    #expect(tw.k == shown)
    let final = "Hello wondrous place"
    tw.end(final)
    #expect(tw.k == len("Hello wond") && tw.text == final)  // cut back to the common prefix
    tw.advance(dt)
    #expect((10...13).contains(tw.k))  // and it carries on from there: no jump, no restart
    let seconds = play(tw)
    #expect(seconds < 2 && tw.view().markdown == final && tw.view().hidden == 0)
}

@Test func cpsZeroIsInstant() {
    let tw = Typewriter(Pace(cps: 0))
    tw.feed("**bo")
    #expect(tw.k == 4 && tw.waiting && tw.view().markdown == "**bo" && tw.view().hidden == 0)  // as the app showed it before
    let moved = tw.advance(dt)
    #expect(!moved && !tw.revealing)
    tw.end("**bold** done")
    #expect(tw.done && tw.view().markdown == "**bold** done" && tw.view().hidden == 0)
}

@Test func setPaceCarriesOnFromTheCharacterShown() {
    let tw = Typewriter()
    tw.feed(prose(100))
    ticks(tw, 10)
    let shown = tw.k
    tw.setPace(Pace(cps: 110))
    #expect(tw.k == shown)
    tw.advance(dt)
    #expect((2...6).contains(tw.k - shown))  // about 110 / 30 characters
    tw.setPace(Pace(cps: 0))
    #expect(tw.k == 100 && tw.view().markdown == prose(100) && tw.view().hidden == 0)
}

@Test func theMouthMovesWithVisibleCharactersAndClosesInAPause() {
    let tw = Typewriter()
    tw.feed("Hi there. Next sentence follows")
    #expect(!tw.revealing)
    while tw.k < len("Hi there.") { tw.advance(0.01) }
    #expect(tw.revealing)
    tw.advance(0.05)
    #expect(tw.revealing && tw.k == len("Hi there."))  // inside talkGap
    tw.advance(0.07)
    #expect(!tw.revealing && tw.k == len("Hi there."))  // the 0.2 s sentence pause is longer
    while tw.k == len("Hi there.") { tw.advance(0.01) }
    #expect(tw.revealing)
}

@Test func resetStartsANewExchange() {
    let tw = atOnce(prose(40))
    tw.advance(dt)
    tw.skip()
    tw.reset()
    #expect(tw.text == "" && tw.k == 0 && !tw.started && !tw.done && !tw.revealing)
    tw.feed("fresh")
    #expect(tw.pending)  // skip did not outlive the exchange
}

/// A tick only bisects and slices; the O(n) plan happens once per delta, never per tick.
@Test func aTickIsCheap() {
    let text = String(repeating: sample0 + "\n\n", count: 4)
    #expect(len(text) > 1000)
    let tw = Typewriter()
    tw.feed(text)
    ticks(tw, 30)
    #expect(tw.pending)
    let plans = tw.plans
    var t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<50 {
        tw.advance(dt)
        _ = tw.view()
    }
    let tick = Double(DispatchTime.now().uptimeNanoseconds - t0) / 50e9
    #expect(tw.plans == plans)
    t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<20 { tw.feed(text) }
    let plan = Double(DispatchTime.now().uptimeNanoseconds - t0) / 20e9
    print("typewriter, \(len(text)) chars: tick \(Int(tick * 1e6)) us, feed \(String(format: "%.2f", plan * 1e3)) ms")
    #expect(tick < 0.005 && plan < 0.03)  // loose: CI machines are slow, an O(n^2) is not (a debug build is ~40x slower than release)
}

// MARK: - golden parity with Python

/// Python 3.14's `str.isspace` (the same set as the regex `\s`) is true for exactly these 29 code points.
@Test func isSpaceIsPythonsIsspace() {
    let python: [UInt32] = [0x9, 0xA, 0xB, 0xC, 0xD, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0, 0x1680]
        + Array(0x2000...0x200A) + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
    let swift = (0..<0x110000 as Range<UInt32>).compactMap(Unicode.Scalar.init).filter { $0.isPySpace }.map(\.value)
    #expect(swift == python)
}

/// Which characters ride with the previous one (a step of 0): Python's unicodedata categories Mn, Me, Cf
/// and Sk (U+5E is an Sk; U+60 is one too but a backtick is a Markdown mark, which costs nothing anyway).
/// Each answer is `"a" + c + "b"` through the Python schedule.
@Test func categoriesDecideWhichCharactersRideAlong() {
    let glued: [(UInt32, Bool)] = [
        (0x301, true), (0xFE0F, true), (0x20E3, true), (0x200D, true), (0x200B, true), (0xAD, true), (0x600, true),
        (0xE0067, true), (0xE007F, true), (0x1F3FB, true), (0x1F3FF, true), (0xA8, true), (0x2C2, true),
        (0x1F1E6, false), (0x1F44D, false), (0x41, false), (0x663, false), (0x20, false), (0x3000, false),
        (0x2028, false), (0xE000, false), (0x10FFFF, false), (0x5E, true), (0x60, false), (0x4E00, false),
        (0x2D, false), (0xD7, false),
    ]
    for (v, rides) in glued {
        let c = Unicode.Scalar(v)!
        let r = Typewriter.schedule([.init("a"), c, .init("b")], Pace(), final: true).r
        #expect((r[1] == r[0]) == rides, "U+\(String(v, radix: 16, uppercase: true))")
    }
}

private let dts = [1.0 / 30, 1.0 / 30, 1.0 / 20, 1.0 / 60, 1.0 / 30, 0.1, 1.0 / 45]  // a jittery 30 Hz timer

private struct Step: Equatable, CustomStringConvertible {
    let tick, k, pending, hidden: Int
    let md: String
    init(_ tick: Int, _ k: Int, _ pending: Int, _ hidden: Int, _ md: String) {
        (self.tick, self.k, self.pending, self.hidden, self.md) = (tick, k, pending, hidden, md)
    }
    static func == (a: Step, b: Step) -> Bool {
        (a.tick, a.k, a.pending, a.hidden) == (b.tick, b.k, b.pending, b.hidden)
            && a.md.unicodeScalars.elementsEqual(b.md.unicodeScalars)
    }
    var description: String { "(\(tick), \(k), \(pending), \(hidden), \(md.debugDescription))" }
}

private func hex(_ x: Double) -> String {
    let s = String(x.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - s.count) + s
}

/// The first 16 hex digits of the SHA-256 of the strings, joined.
private func digest(_ parts: [String]) -> String {
    var h = SHA256()
    for p in parts { h.update(data: Data(p.utf8)) }
    return h.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description
}

/// Runs a Typewriter and records it after every tick and every call.
private final class Rec {
    let tw: Typewriter
    var n = 0
    var lines: [String] = []
    var steps: [Step] = []
    init(_ tw: Typewriter) { self.tw = tw }

    func note(_ ret: Bool = false) {
        let (md, hidden) = tw.view()
        let pending = len(tw.text) - tw.k
        let flags = [tw.revealing, tw.waiting, tw.done, tw.started].map { $0 ? "1" : "0" }.joined()
        lines.append("\(n)|\(ret ? 1 : 0)|\(tw.k)|\(pending)|\(hidden)|\(flags)|\(hex(tw.fraction))|\(md)\n")
        let cur = Step(n, tw.k, pending, hidden, md)
        if steps.last.map({ ($0.k, $0.pending, $0.hidden) == (cur.k, cur.pending, cur.hidden)
            && $0.md.unicodeScalars.elementsEqual(md.unicodeScalars) }) != true {
            steps.append(cur)
        }
    }

    func tick() {
        let ret = tw.advance(dts[n % dts.count])
        n += 1
        note(ret)
    }

    func ticks(_ count: Int) { for _ in 0..<count { tick() } }
}

private func recAtOnce(_ text: String, _ pace: Pace = Pace(), limit: Int = 4000) -> Rec {
    let rec = Rec(Typewriter(pace))
    rec.tw.feed(text); rec.note()
    rec.tw.end(); rec.note()
    while !rec.tw.done && rec.n < limit { rec.tick() }
    return rec
}

private func recStreamed(_ text: String, chunk: Int, every: Int, limit: Int = 4000) -> Rec {
    let rec = Rec(Typewriter())
    let tw = rec.tw, total = len(text)
    var got = 0
    while !tw.done && rec.n < limit {
        if got < total && rec.n % every == 0 {
            got = min(total, got + chunk)
            tw.feed(head(text, got)); rec.note()
            if got == total { tw.end(); rec.note() }
        }
        rec.tick()
    }
    return rec
}

private func recSkipMid() -> Rec {
    let rec = Rec(Typewriter())
    rec.tw.feed(head(plain, 60)); rec.note()
    rec.ticks(8)
    rec.tw.skip(); rec.note()
    rec.ticks(3)
    rec.tw.feed(plain); rec.note()
    rec.tick()
    rec.tw.end(plain + " Bye."); rec.note()
    rec.tick()
    return rec
}

private func recRetype() -> Rec {
    let rec = Rec(Typewriter())
    rec.tw.feed(retypeA); rec.note()
    rec.ticks(10)
    rec.tw.end(retypeA + ", and more"); rec.note()
    rec.tick()
    rec.tw.end("Hello wondrous place"); rec.note()
    while !rec.tw.done && rec.n < 400 { rec.tick() }
    return rec
}

private func recPaceChange() -> Rec {
    let rec = Rec(Typewriter())
    rec.tw.feed(plain + " " + prose(60)); rec.note()
    rec.ticks(10)
    rec.tw.setPace(Pace(cps: 110)); rec.note()
    rec.ticks(5)
    var slow = Pace(cps: 20)
    slow.sentence = 0.5
    rec.tw.setPace(slow); rec.note()
    rec.ticks(5)
    rec.tw.end(); rec.note()
    rec.ticks(5)
    rec.tw.setPace(Pace(cps: 0)); rec.note()
    rec.tick()
    return rec
}

private func recCpsZero() -> Rec {
    let rec = Rec(Typewriter(Pace(cps: 0)))
    rec.tw.feed("**bo"); rec.note()
    rec.tick()
    rec.tw.feed("**bold** do"); rec.note()
    rec.tw.end("**bold** done"); rec.note()
    rec.tick()
    return rec
}

private let plain = "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes.\nDone (really)."
private let retypeA = "Hello wonderful world, how are you today my friend"
private let unicode = "Caf\u{E9} e\u{301} \u{1F1F3}\u{1F1F1}\u{1F1E9}\u{1F1EA} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} 1\u{FE0F}\u{20E3} \u{1D400}\u{1D401} \u{65E5}\u{672C}\u{8A9E} \u{20000} \u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F} \u{270C}\u{1F3FD} **bold \u{1F600}** `code \u{1F600}` [link \u{1F600}](http://x.io/\u{1F600})"
private let emoji = "a\u{1F44D}\u{1F3FD} \u{1F1F3}\u{1F1F1}\u{1F1E9}\u{1F1EA} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} 1\u{FE0F}\u{20E3} e\u{301} \u{1D400} **b\u{1F600}**"
private let marks = "**bo and *it* and __under__ and ~~gone~~ and `co **de`\n2*3 is six, 2 * 3 too\n* item one\n+ item two\n1) item three\n> > deep quote\n   - nested [a](b\n[no url] and [x](y) and [z\n####### not a heading\n########\n-\titem with tab\n\u{661}. arabic digit\n    four spaces\nend -"
private let code = "Run:\n\n````sh\nls **x**\n```\nnot closed yet\n````\n\nthen ~~~\n~~~py\nprint(1) # hi. there\n~~~\n\n```\nunclosed"
private let ws = "a\r\nb\u{A0}c\u{3000}d\u{2028}e\tf\u{1C}g  \n\n\n  - x"
private let long = String(repeating: sample0 + "\n\n" + sample1 + "\n\n", count: 8)

private struct Golden {
    let name: String
    let make: () -> Rec
    let ticks, steps, lines: Int
    let digest: String
    var full: [Step]?
}

private let goldens: [Golden] = [
    Golden(name: "sample0-at-once", make: { recAtOnce(sample0) }, ticks: 65, steps: 49, lines: 67, digest: "438e58fc7c453d76"),
    Golden(name: "sample0-stream-1x1", make: { recStreamed(sample0, chunk: 1, every: 1) }, ticks: 288, steps: 497, lines: 577, digest: "c1f3ef36efc8f8c6"),
    Golden(name: "sample1-at-once", make: { recAtOnce(sample1) }, ticks: 69, steps: 54, lines: 71, digest: "ac0a062fa259ef36"),
    Golden(name: "sample1-stream-3x2", make: { recStreamed(sample1, chunk: 3, every: 2) }, ticks: 230, steps: 257, lines: 342, digest: "a001f46d8d4d6dc7"),
    Golden(name: "plain-at-once", make: { recAtOnce(plain) }, ticks: 49, steps: 30, lines: 51, digest: "6ff7e2cf86af0328", full: plainAtOnce),
    Golden(name: "plain-stream-5x3", make: { recStreamed(plain, chunk: 5, every: 3) }, ticks: 71, steps: 61, lines: 89, digest: "cf93357ab7853387", full: plainStream),
    Golden(name: "unicode-at-once", make: { recAtOnce(unicode) }, ticks: 21, steps: 22, lines: 23, digest: "fcd6c26af67f194e"),
    Golden(name: "unicode-stream-1x2", make: { recStreamed(unicode, chunk: 1, every: 2) }, ticks: 171, steps: 167, lines: 258, digest: "855eaa363225c251"),
    Golden(name: "emoji-at-once", make: { recAtOnce(emoji) }, ticks: 8, steps: 9, lines: 10, digest: "5db7a3f99718f6c0", full: emojiAtOnce),
    Golden(name: "emoji-stream-1x1", make: { recStreamed(emoji, chunk: 1, every: 1) }, ticks: 30, steps: 56, lines: 61, digest: "6b11c49b9c7fc38a"),
    Golden(name: "marks-at-once", make: { recAtOnce(marks) }, ticks: 62, steps: 56, lines: 64, digest: "e330b80b0559cdd1"),
    Golden(name: "marks-stream-1x1", make: { recStreamed(marks, chunk: 1, every: 1) }, ticks: 258, steps: 428, lines: 516, digest: "57060364fb72739b"),
    Golden(name: "code-at-once", make: { recAtOnce(code) }, ticks: 34, steps: 22, lines: 36, digest: "d1c1755d864e9232", full: codeAtOnce),
    Golden(name: "code-stream-2x2", make: { recStreamed(code, chunk: 2, every: 2) }, ticks: 99, steps: 89, lines: 150, digest: "2d2a9ff72ddd3a58"),
    Golden(name: "ws-at-once", make: { recAtOnce(ws) }, ticks: 16, steps: 12, lines: 18, digest: "af8e7db22fed7948", full: wsAtOnce),
    Golden(name: "long-at-once", make: { recAtOnce(long) }, ticks: 353, steps: 329, lines: 355, digest: "34353a971c75445d"),
    Golden(name: "long-stream-24x3", make: { recStreamed(long, chunk: 24, every: 3) }, ticks: 694, steps: 815, lines: 903, digest: "799de4f9f1f8b456"),
    Golden(name: "skip-mid", make: recSkipMid, ticks: 13, steps: 10, lines: 17, digest: "2474e15aac7a6817"),
    Golden(name: "retype", make: recRetype, ticks: 15, steps: 17, lines: 18, digest: "3fa2cbedc62bd41e", full: retypeSteps),
    Golden(name: "pace-change", make: recPaceChange, ticks: 26, steps: 19, lines: 31, digest: "ca226186e01a7376"),
    Golden(name: "cps-zero", make: recCpsZero, ticks: 2, steps: 3, lines: 5, digest: "7a58c8c06d27585b", full: cpsZeroSteps),
]

/// Replies fed whole or in chunks, skipped, retyped, re-paced: the shown prefix, the pending count and
/// the flags at every tick are the Python typewriter's.
@Test(arguments: goldens.map(\.name))
func theTraceIsPythons(name: String) {
    let g = goldens.first { $0.name == name }!
    let rec = g.make()
    if let full = g.full {
        for (i, (got, want)) in zip(rec.steps, full).enumerated() where got != want {
            Issue.record("step \(i): got \(got), Python \(want)")
            break
        }
        #expect(rec.steps.count == full.count)
    }
    #expect((rec.n, rec.steps.count, rec.lines.count) == (g.ticks, g.steps, g.lines))
    #expect(digest(rec.lines) == g.digest)
}

/// classify + schedule (kinds, code flags, reveal times to the last bit; with and without the end of
/// the run) and markdownPrefix for every k, per reply.
private func scheduleParts(_ text: String) -> [String] {
    var out: [String] = []
    for final in [true, false] {
        let (r, kind, code) = Typewriter.schedule(scalars(text), Pace(), final: final)
        out.append(kind.map { $0 == .visible ? "0" : $0 == .opening ? "1" : "2" }.joined() + "\n")
        out.append(code.map { $0 ? "1" : "0" }.joined() + "\n")
        out.append(r.map(hex).joined(separator: " ") + "\n")
    }
    return out
}

private func prefixParts(_ text: String) -> [String] {
    var out: [String] = []
    for final in [true, false] {
        let chars = scalars(text)
        let kind = Typewriter.schedule(chars, Pace(), final: final).kind
        for k in 0...chars.count {
            let (md, hidden) = Typewriter.markdownPrefix(chars, kind, k)
            out.append("\(k)|\(hidden)|\(md)\n")
        }
    }
    return out
}

private let layers: [(name: String, text: String, count: Int, schedule: String, prefix: String)] = [
    ("sample0", sample0, 288, "42b899f29772529b", "531c9cdb8cfb9e12"),
    ("sample1", sample1, 332, "65addc9dc229631f", "41f4df5380ad574f"),
    ("plain", plain, 85, "ec6846b79644b249", "ad12c770a01cab9a"),
    ("unicode", unicode, 86, "a7379c33104ec610", "5d9048f6a4a03a29"),
    ("emoji", emoji, 30, "943f01d731b02770", "524f8444da6482a4"),
    ("marks", marks, 257, "eda04a20cf45ef72", "559d0cfc424afab6"),
    ("code", code, 100, "3b4461296cd6b6b8", "2226551265932f75"),
    ("ws", ws, 24, "20490ec0676ce82c", "b516f8b7fc8c135e"),
    ("long", long, 4992, "f77ff5e545a7edc8", "060fd3a35592f80c"),
]

@Test(arguments: layers.map(\.name))
func scheduleAndPrefixArePythons(name: String) {
    let l = layers.first { $0.name == name }!
    #expect(len(l.text) == l.count)  // the corpus was transcribed right
    #expect(digest(scheduleParts(l.text)) == l.schedule)
    #expect(digest(prefixParts(l.text)) == l.prefix)
}

@Test func theScheduleOfATinyReplyIsPythonsToTheLastBit() {
    let a = Typewriter.schedule(scalars("**hi**"), Pace(), final: true)
    #expect(a.kind == [.opening, .opening, .visible, .visible, .closing, .closing])
    #expect(a.r == [0.01818181818181818, 0.01818181818181818, 0.01818181818181818,
                    0.03636363636363636, 0.03636363636363636, 0.03636363636363636])
    let b = Typewriter.schedule(scalars("Hi. **yo**\n- x"), Pace(), final: true)
    #expect(b.kind == [.visible, .visible, .visible, .visible, .opening, .opening, .visible, .visible,
                       .closing, .closing, .visible, .opening, .opening, .visible])
    #expect(b.r == [0.01818181818181818, 0.03636363636363636, 0.05454545454545454, 0.27272727272727276,
                    0.29090909090909095, 0.29090909090909095, 0.29090909090909095, 0.30909090909090914,
                    0.30909090909090914, 0.30909090909090914, 0.3272727272727273, 0.42545454545454553,
                    0.42545454545454553, 0.42545454545454553])
}

private let tokens: [String] = [
    "a", "bc", "x ", " ", "  ", "\n", "\n\n", "\t", "**", "*", "__", "_", "~~", "`", "```\n", "~~~\n", "````",
    "[", "](", ")", "]", "(", "- ", "-", "* ", "+ ", "> ", "# ", "###### ", "####### ", "1. ", "12) ",
    "\u{661}. ", ". ", "! ", "? ", "... ", "\u{2026}", ", ", ": ", "; ", "\"", "'", "e\u{301}",
    "\u{1F44D}\u{1F3FD}", "\u{1F1F3}\u{1F1F1}", "\u{1F468}\u{200D}\u{1F469}", "\u{1F600}", "\u{200D}",
    "\u{FE0F}", "\u{20E3}", "\u{65E5}\u{672C}", "\u{20000}", "\r", "\u{A0}", "\u{3000}", "\u{1D400}",
]

/// Random replies made of mark, emoji, whitespace and punctuation pieces (the same SplitMix64 stream in Python).
private func fuzzText(_ i: Int) -> String {
    var rng = SplitMix64(seed: UInt64(i))
    let n = 3 + Int(rng.next() % 40)
    return (0..<n).map { _ in tokens[Int(rng.next() % UInt64(tokens.count))] }.joined()
}

/// The three digests of one fuzz reply: schedule, prefix, and the traces of a whole and a streamed delivery.
private func fuzzDigests(_ text: String) -> [String] {
    [digest(scheduleParts(text)), digest(prefixParts(text)),
     digest(recAtOnce(text).lines + recStreamed(text, chunk: 2, every: 1).lines)]
}

@Test func threeHundredRandomRepliesAreHandledAsPythonDoes() {
    var acc = [SHA256(), SHA256(), SHA256()]
    for i in 0..<300 {
        for (j, d) in fuzzDigests(fuzzText(i)).enumerated() { acc[j].update(data: Data(d.utf8)) }
    }
    let got = acc.map { $0.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description }
    #expect(got == ["0c84afd87b7d49da", "6ac705898810f69d", "c3ade255a30eaac0"])
}

// The full traces of the small scenarios: (tick, k, pending, hidden, markdown).

private let plainAtOnce: [Step] = [
    Step(0, 0, 85, 5, "Hello"),
    Step(1, 5, 80, 0, "Hello"),
    Step(2, 10, 75, 2, "Hello there!"),
    Step(3, 12, 73, 0, "Hello there!"),
    Step(5, 13, 72, 2, "Hello there! It"),
    Step(6, 26, 59, 6, "Hello there! It is 3.14 o'clock,"),
    Step(7, 28, 57, 4, "Hello there! It is 3.14 o'clock,"),
    Step(8, 32, 53, 0, "Hello there! It is 3.14 o'clock,"),
    Step(10, 37, 48, 4, "Hello there! It is 3.14 o'clock, see v1.2"),
    Step(11, 39, 46, 2, "Hello there! It is 3.14 o'clock, see v1.2"),
    Step(12, 42, 43, 6, "Hello there! It is 3.14 o'clock, see v1.2 now..."),
    Step(13, 48, 37, 0, "Hello there! It is 3.14 o'clock, see v1.2 now..."),
    Step(16, 49, 36, 5, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay;"),
    Step(17, 53, 32, 1, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay;"),
    Step(18, 54, 31, 0, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay;"),
    Step(20, 60, 25, 0, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine:"),
    Step(23, 62, 23, 2, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?"),
    Step(24, 64, 21, 0, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?"),
    Step(29, 65, 20, 0, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n"),
    Step(30, 66, 19, 4, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes."),
    Step(34, 68, 17, 2, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes."),
    Step(35, 69, 16, 1, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes."),
    Step(36, 70, 15, 0, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes."),
    Step(41, 71, 14, 4, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes.\nDone"),
    Step(44, 73, 12, 2, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes.\nDone"),
    Step(45, 76, 9, 9, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes.\nDone (really)."),
    Step(46, 77, 8, 8, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes.\nDone (really)."),
    Step(47, 79, 6, 6, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes.\nDone (really)."),
    Step(48, 84, 1, 1, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes.\nDone (really)."),
    Step(49, 85, 0, 0, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes.\nDone (really)."),
]

private let plainStream: [Step] = [
    Step(0, 0, 5, 5, "Hello"),
    Step(1, 1, 4, 4, "Hello"),
    Step(2, 3, 2, 2, "Hello"),
    Step(3, 5, 0, 0, "Hello"),
    Step(3, 5, 5, 0, "Hello"),
    Step(5, 7, 3, 3, "Hello ther"),
    Step(6, 10, 0, 0, "Hello ther"),
    Step(6, 10, 5, 2, "Hello there!"),
    Step(7, 11, 4, 1, "Hello there!"),
    Step(8, 12, 3, 0, "Hello there!"),
    Step(9, 12, 8, 0, "Hello there!"),
    Step(12, 12, 13, 0, "Hello there!"),
    Step(13, 14, 11, 1, "Hello there! It"),
    Step(14, 16, 9, 2, "Hello there! It is"),
    Step(15, 17, 8, 1, "Hello there! It is"),
    Step(15, 17, 13, 1, "Hello there! It is"),
    Step(16, 19, 11, 4, "Hello there! It is 3.14"),
    Step(17, 22, 8, 1, "Hello there! It is 3.14"),
    Step(18, 23, 7, 0, "Hello there! It is 3.14"),
    Step(18, 23, 12, 0, "Hello there! It is 3.14"),
    Step(19, 25, 10, 7, "Hello there! It is 3.14 o'clock,"),
    Step(20, 30, 5, 2, "Hello there! It is 3.14 o'clock,"),
    Step(21, 32, 3, 0, "Hello there! It is 3.14 o'clock,"),
    Step(21, 32, 8, 0, "Hello there! It is 3.14 o'clock,"),
    Step(24, 34, 6, 2, "Hello there! It is 3.14 o'clock, see"),
    Step(24, 34, 11, 2, "Hello there! It is 3.14 o'clock, see"),
    Step(25, 35, 10, 1, "Hello there! It is 3.14 o'clock, see"),
    Step(26, 37, 8, 4, "Hello there! It is 3.14 o'clock, see v1.2"),
    Step(27, 42, 3, 3, "Hello there! It is 3.14 o'clock, see v1.2 now"),
    Step(27, 42, 8, 6, "Hello there! It is 3.14 o'clock, see v1.2 now..."),
    Step(28, 44, 6, 4, "Hello there! It is 3.14 o'clock, see v1.2 now..."),
    Step(29, 45, 5, 3, "Hello there! It is 3.14 o'clock, see v1.2 now..."),
    Step(30, 47, 3, 1, "Hello there! It is 3.14 o'clock, see v1.2 now..."),
    Step(30, 47, 8, 1, "Hello there! It is 3.14 o'clock, see v1.2 now..."),
    Step(31, 48, 7, 0, "Hello there! It is 3.14 o'clock, see v1.2 now..."),
    Step(33, 48, 12, 0, "Hello there! It is 3.14 o'clock, see v1.2 now..."),
    Step(36, 50, 10, 4, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay;"),
    Step(36, 50, 15, 4, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay;"),
    Step(37, 52, 13, 2, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay;"),
    Step(38, 54, 11, 0, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay;"),
    Step(39, 54, 16, 0, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay;"),
    Step(41, 59, 11, 1, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine:"),
    Step(42, 60, 10, 0, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine:"),
    Step(42, 60, 15, 0, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine:"),
    Step(45, 63, 12, 1, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?"),
    Step(45, 63, 17, 1, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?"),
    Step(46, 64, 16, 0, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?"),
    Step(48, 64, 21, 0, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?"),
    Step(51, 65, 20, 0, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n"),
    Step(52, 66, 19, 4, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes."),
    Step(56, 67, 18, 3, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes."),
    Step(57, 69, 16, 1, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes."),
    Step(58, 70, 15, 0, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes."),
    Step(62, 71, 14, 4, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes.\nDone"),
    Step(65, 72, 13, 3, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes.\nDone"),
    Step(66, 74, 11, 1, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes.\nDone"),
    Step(67, 75, 10, 0, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes.\nDone"),
    Step(68, 77, 8, 8, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes.\nDone (really)."),
    Step(69, 83, 2, 2, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes.\nDone (really)."),
    Step(70, 84, 1, 1, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes.\nDone (really)."),
    Step(71, 85, 0, 0, "Hello there! It is 3.14 o'clock, see v1.2 now... Okay; fine: go?\n\nYes.\nDone (really)."),
]

private let emojiAtOnce: [Step] = [
    Step(0, 0, 30, 5, "a\u{1F44D}\u{1F3FD}"),
    Step(1, 1, 29, 4, "a\u{1F44D}\u{1F3FD}"),
    Step(2, 4, 26, 8, "a\u{1F44D}\u{1F3FD} \u{1F1F3}\u{1F1F1}\u{1F1E9}\u{1F1EA}"),
    Step(3, 9, 21, 8, "a\u{1F44D}\u{1F3FD} \u{1F1F3}\u{1F1F1}\u{1F1E9}\u{1F1EA} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"),
    Step(4, 14, 16, 0, "a\u{1F44D}\u{1F3FD} \u{1F1F3}\u{1F1F1}\u{1F1E9}\u{1F1EA} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"),
    Step(5, 18, 12, 0, "a\u{1F44D}\u{1F3FD} \u{1F1F3}\u{1F1F1}\u{1F1E9}\u{1F1EA} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} 1\u{FE0F}\u{20E3}"),
    Step(6, 24, 6, 0, "a\u{1F44D}\u{1F3FD} \u{1F1F3}\u{1F1F1}\u{1F1E9}\u{1F1EA} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} 1\u{FE0F}\u{20E3} e\u{301} \u{1D400} "),
    Step(7, 27, 3, 2, "a\u{1F44D}\u{1F3FD} \u{1F1F3}\u{1F1F1}\u{1F1E9}\u{1F1EA} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} 1\u{FE0F}\u{20E3} e\u{301} \u{1D400} **b\u{1F600}**"),
    Step(8, 30, 0, 0, "a\u{1F44D}\u{1F3FD} \u{1F1F3}\u{1F1F1}\u{1F1E9}\u{1F1EA} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} 1\u{FE0F}\u{20E3} e\u{301} \u{1D400} **b\u{1F600}**"),
]

private let codeAtOnce: [Step] = [
    Step(0, 0, 100, 4, "Run:"),
    Step(1, 2, 98, 2, "Run:"),
    Step(2, 4, 96, 0, "Run:"),
    Step(3, 5, 95, 0, "Run:\n"),
    Step(4, 6, 94, 0, "Run:\n\n"),
    Step(6, 14, 86, 1, "Run:\n\n````sh\nls"),
    Step(7, 17, 83, 4, "Run:\n\n````sh\nls **x**"),
    Step(8, 21, 79, 0, "Run:\n\n````sh\nls **x**"),
    Step(9, 25, 75, 0, "Run:\n\n````sh\nls **x**\n````"),
    Step(10, 28, 72, 1, "Run:\n\n````sh\nls **x**\n```\nnot"),
    Step(11, 30, 70, 6, "Run:\n\n````sh\nls **x**\n```\nnot closed"),
    Step(12, 34, 66, 2, "Run:\n\n````sh\nls **x**\n```\nnot closed"),
    Step(13, 46, 54, 0, "Run:\n\n````sh\nls **x**\n```\nnot closed yet\n````\n"),
    Step(14, 47, 53, 4, "Run:\n\n````sh\nls **x**\n```\nnot closed yet\n````\n\nthen"),
    Step(20, 52, 48, 0, "Run:\n\n````sh\nls **x**\n```\nnot closed yet\n````\n\nthen "),
    Step(21, 56, 44, 0, "Run:\n\n````sh\nls **x**\n```\nnot closed yet\n````\n\nthen ~~~\n"),
    Step(24, 66, 34, 4, "Run:\n\n````sh\nls **x**\n```\nnot closed yet\n````\n\nthen ~~~\n~~~py\nprint(1)"),
    Step(25, 68, 32, 2, "Run:\n\n````sh\nls **x**\n```\nnot closed yet\n````\n\nthen ~~~\n~~~py\nprint(1)"),
    Step(26, 72, 28, 0, "Run:\n\n````sh\nls **x**\n```\nnot closed yet\n````\n\nthen ~~~\n~~~py\nprint(1) #"),
    Step(27, 87, 13, 0, "Run:\n\n````sh\nls **x**\n```\nnot closed yet\n````\n\nthen ~~~\n~~~py\nprint(1) # hi. there\n~~~\n"),
    Step(29, 88, 12, 0, "Run:\n\n````sh\nls **x**\n```\nnot closed yet\n````\n\nthen ~~~\n~~~py\nprint(1) # hi. there\n~~~\n\n"),
    Step(34, 100, 0, 0, "Run:\n\n````sh\nls **x**\n```\nnot closed yet\n````\n\nthen ~~~\n~~~py\nprint(1) # hi. there\n~~~\n\n```\nunclosed"),
]

private let wsAtOnce: [Step] = [
    Step(0, 0, 24, 1, "a"),
    Step(1, 1, 23, 0, "a"),
    Step(2, 3, 21, 1, "a\r\nb"),
    Step(5, 4, 20, 0, "a\r\nb"),
    Step(6, 10, 14, 0, "a\r\nb\u{A0}c\u{3000}d\u{2028}e"),
    Step(7, 11, 13, 1, "a\r\nb\u{A0}c\u{3000}d\u{2028}e\tf"),
    Step(8, 13, 11, 1, "a\r\nb\u{A0}c\u{3000}d\u{2028}e\tf\u{1C}g"),
    Step(9, 15, 9, 0, "a\r\nb\u{A0}c\u{3000}d\u{2028}e\tf\u{1C}g "),
    Step(10, 17, 7, 0, "a\r\nb\u{A0}c\u{3000}d\u{2028}e\tf\u{1C}g  \n"),
    Step(11, 18, 6, 0, "a\r\nb\u{A0}c\u{3000}d\u{2028}e\tf\u{1C}g  \n\n"),
    Step(12, 19, 5, 0, "a\r\nb\u{A0}c\u{3000}d\u{2028}e\tf\u{1C}g  \n\n\n"),
    Step(16, 24, 0, 0, "a\r\nb\u{A0}c\u{3000}d\u{2028}e\tf\u{1C}g  \n\n\n  - x"),
]

private let retypeSteps: [Step] = [
    Step(0, 0, 50, 5, "Hello"),
    Step(1, 1, 49, 4, "Hello"),
    Step(2, 3, 47, 2, "Hello"),
    Step(3, 6, 44, 9, "Hello wonderful"),
    Step(4, 7, 43, 8, "Hello wonderful"),
    Step(5, 9, 41, 6, "Hello wonderful"),
    Step(6, 14, 36, 1, "Hello wonderful"),
    Step(7, 15, 35, 0, "Hello wonderful"),
    Step(8, 17, 33, 5, "Hello wonderful world,"),
    Step(9, 19, 31, 3, "Hello wonderful world,"),
    Step(10, 22, 28, 0, "Hello wonderful world,"),
    Step(10, 22, 38, 0, "Hello wonderful world,"),
    Step(11, 10, 10, 4, "Hello wondrous"),
    Step(12, 11, 9, 3, "Hello wondrous"),
    Step(13, 17, 3, 3, "Hello wondrous place"),
    Step(14, 18, 2, 2, "Hello wondrous place"),
    Step(15, 20, 0, 0, "Hello wondrous place"),
]

private let cpsZeroSteps: [Step] = [
    Step(0, 4, 0, 0, "**bo"),
    Step(1, 11, 0, 0, "**bold** do"),
    Step(1, 13, 0, 0, "**bold** done"),
]
