// Port of tests/test_feelings.py, plus a few cases on Python-specific string handling (Unicode
// whitespace, combining marks) whose expected results were produced by the Python code.
import Testing
@testable import RoboCore

private func runFilter(_ deltas: String...) -> [Event] {
    var f = FeelingFilter()
    let out = deltas.flatMap { f.feed($0) }
    return out + f.finish()
}

private func text(_ events: [Event]) -> String {
    events.reduce("") { acc, e in if case .delta(let t) = e { acc + t } else { acc } }
}

private func feelings(_ events: [Event]) -> [String] {
    events.compactMap { if case .feeling(let e) = $0 { e } else { nil } }
}

/// Events as strings, with every non-ASCII scalar spelled out (Swift's == would hide a
/// difference between a character and its canonical equivalent).
private func shown(_ events: [Event]) -> [String] {
    func esc(_ s: String) -> String {
        s.unicodeScalars.map { $0.value < 0x7F && $0.value >= 0x20 ? String($0) : "\\u{\(String($0.value, radix: 16))}" }.joined()
    }
    return events.map {
        switch $0 {
        case .feeling(let e): "feel:\(e)"
        case .delta(let t): "text:\(esc(t))"
        default: "?"
        }
    }
}

@Suite("Feelings")
struct FeelingsTests {
    @Test func wholeTagThenText() {
        #expect(runFilter("[[feel:curious]] Hi there") == [.feeling("curious"), .delta("Hi there")])
    }

    @Test func tagSplitAcrossDeltas() {
        var f = FeelingFilter()
        #expect(f.feed("[[fe") == [])
        #expect(f.feed("el:hap") == [])
        #expect(f.feed("py]] Hi") == [.feeling("happy"), .delta("Hi")])
        #expect(f.feed(" you") == [.delta(" you")])
        #expect(f.finish() == [])
    }

    @Test func spaceAfterTagInNextDeltaIsStrippedOnce() {
        #expect(runFilter("[[feel:calm]]", "\n", "\nok") == [.feeling("calm"), .delta("\nok")])
    }

    @Test func leadingWhitespaceBeforeTag() {
        #expect(runFilter("  ", "\n[[feel:sad]]Oh") == [.feeling("sad"), .delta("Oh")])
    }

    @Test func unknownEmotionIsNeutral() {
        #expect(runFilter("[[feel:Ecstatic]] Yo") == [.feeling("neutral"), .delta("Yo")])
    }

    @Test func uppercaseKnownEmotion() {
        #expect(feelings(runFilter("[[feel:Happy]] Yo")) == ["happy"])
    }

    @Test func noTagPassesThroughImmediately() {
        var f = FeelingFilter()
        #expect(f.feed("Hello") == [.feeling("neutral"), .delta("Hello")])
        #expect(f.feed(" world") == [.delta(" world")])
        #expect(f.finish() == [])
    }

    @Test func bracketStartThatIsNotATag() {
        var f = FeelingFilter()
        #expect(f.feed("[") == [])
        #expect(f.feed("1] item") == [.feeling("neutral"), .delta("[1] item")])
    }

    @Test func incompleteTagFlushedAsTextOnFinish() {
        var f = FeelingFilter()
        #expect(f.feed("[[feel:hap") == [])
        #expect(f.finish() == [.feeling("neutral"), .delta("[[feel:hap")])
    }

    @Test func overlongPrefixStopsBuffering() {
        let long = "[[feel:" + String(repeating: "x", count: 50)
        #expect(runFilter(long) == [.feeling("neutral"), .delta(long)])
    }

    @Test func emptyReplyStillGetsOneFeeling() {
        #expect(runFilter() == [.feeling("neutral")])
    }

    @Test func laterTagIsStrippedAndShiftsMood() {
        let ev = runFilter("[[feel:happy]] Great. [[feel:concerned]]But wait.")
        #expect(feelings(ev) == ["happy", "concerned"])
        #expect(text(ev) == "Great. But wait.")
        #expect(ev.firstIndex(of: .feeling("concerned"))! > ev.firstIndex(of: .delta("Great. "))!)
    }

    @Test func laterTagSplitAcrossDeltas() {
        var f = FeelingFilter()
        #expect(f.feed("[[feel:happy]] A [[fe") == [.feeling("happy"), .delta("A ")])
        #expect(f.feed("el:sad]] B") == [.feeling("sad"), .delta(" B")])
    }

    @Test func laterUnknownTagStrippedWithoutFeeling() {
        let ev = runFilter("Hi [[feel:weird]]there")
        #expect(feelings(ev) == ["neutral"])
        #expect(text(ev) == "Hi there")
    }

    @Test func repeatedLeadingTag() {
        let ev = runFilter("[[feel:happy]] [[feel:happy]] Hi")
        #expect(text(ev) == " Hi")
        #expect(feelings(ev) == ["happy"])  // a repeat is not a mood shift
    }

    @Test func plainBracketsMidTextNotHeld() {
        var f = FeelingFilter()
        f.feed("Hi ")
        #expect(f.feed("a[1] b") == [.delta("a[1] b")])
        #expect(f.feed("x [") == [.delta("x ")])
        #expect(f.feed("y") == [.delta("[y")])
    }

    @Test func oneLeadingFeelingBeforeAnyDelta() {
        for chunks in [["[[feel:proud]]x"], ["x"], ["[", "["], [" "]] {
            var f = FeelingFilter()
            let ev = chunks.flatMap { f.feed($0) } + f.finish()
            guard case .feeling = ev[0] else { Issue.record("no leading feeling for \(chunks)"); continue }
            #expect(feelings(ev).count == 1)
        }
    }

    @Test func everySplitPointGivesSameResult() {
        let s = Array("[[feel:playful]] Hey [[feel:sad]]oh no [x] [[feel".unicodeScalars)
        func part(_ r: Range<Int>) -> String { String(String.UnicodeScalarView(s[r])) }
        let whole = runFilter(part(0..<s.count))
        for i in 0...s.count {
            for j in i...s.count {
                let ev = runFilter(part(0..<i), part(i..<j), part(j..<s.count))
                #expect(feelings(ev) == feelings(whole))
                #expect(text(ev) == "Hey oh no [x] [[feel" && text(whole) == "Hey oh no [x] [[feel")
            }
        }
    }

    @Test func stripTagsRemovesEveryTag() {
        #expect(stripTags("[[feel:happy]] Hi [[feel:sad]]there\n") == "Hi there")
        #expect(stripTags("plain [x]") == "plain [x]")
    }

    @Test func paddedLeadingTagStillParsesWhenStreamed() {
        var f = FeelingFilter()
        let s = "[[feel:" + String(repeating: " ", count: 35) + "happy]] Hi"
        let out = s.map { f.feed(String($0)) }.flatMap { $0 } + f.finish()
        #expect(out[0] == .feeling("happy"))
        #expect(text(out) == "Hi")
    }

    // MARK: Python's str semantics (expected values computed by FeelingFilter in Python)

    @Test func pythonWhitespaceAndCombiningMarks() {
        // lstrip() takes NBSP and U+3000; a combining mark after the tag is the next text
        #expect(shown(runFilter("\u{a0}\u{3000}[[feel:sad]]\u{301}Oh")) == ["feel:sad", "text:\\u{301}Oh"])
        // the one skipped character after the leading tag is only " " or "\n", not U+2028
        #expect(shown(runFilter("[[feel:happy]]\u{2028} a]]\u{301} [[feel:\u{a0}Calm\u{a0}]]b"))
            == ["feel:happy", "text:\\u{2028} a]]\\u{301} ", "feel:calm", "text:b"])
        #expect(shown(runFilter("[[feel:Happy]]", "\u{301}", " x")) == ["feel:happy", "text:\\u{301}", "text: x"])
        #expect(shown(runFilter("\u{1f}[[feel:calm]] \n\nhi")) == ["feel:calm", "text:\\u{a}\\u{a}hi"])
        #expect(stripTags("\u{3000}[[feel:happy]]\u{301} x [[feel:sad]]\u{a0}").unicodeScalars.map(\.value) == [0x301, 0x20, 0x78])
    }
}
