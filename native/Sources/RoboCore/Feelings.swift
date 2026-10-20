// Split Hermes's `[[feel:x]]` emotion tags out of streamed reply text. Port of src/robo/feelings.py.
// Python indexes code points, so the text is held as unicode scalars: a Swift Character would
// fuse a "]" with a combining mark after it and the tag would stop matching.

private typealias Scalars = [Unicode.Scalar]
private let tagOpen = Array("[[feel:".unicodeScalars)
private let cap = 80  // longest text held while it might still become a tag

private func text(_ s: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(s)) }

private func stripped(_ s: ArraySlice<Unicode.Scalar>) -> ArraySlice<Unicode.Scalar> {
    var t = s
    while let c = t.first, c.isPySpace { t.removeFirst() }
    while let c = t.last, c.isPySpace { t.removeLast() }
    return t
}

/// The complete tag `[[feel:x]]` at `i`: where it ends and its `x`; nil if none starts there.
private func tag(_ s: Scalars, at i: Int) -> (end: Int, raw: ArraySlice<Unicode.Scalar>)? {
    let n = tagOpen.count
    guard i + n <= s.count, s[i..<i + n].elementsEqual(tagOpen) else { return nil }
    var j = i + n
    while j < s.count, s[j] != "[", s[j] != "]" { j += 1 }
    guard j + 1 < s.count, s[j] == "]", s[j + 1] == "]" else { return nil }
    return (j + 2, s[i + n..<j])
}

/// True if `s` could still grow into a complete tag.
private func partial(_ s: ArraySlice<Unicode.Scalar>) -> Bool {
    if s.count >= cap { return false }
    if s.count <= tagOpen.count { return tagOpen.starts(with: s) }
    guard s.starts(with: tagOpen) else { return false }
    let rest = s.dropFirst(tagOpen.count)
    return !(rest.last == "]" ? rest.dropLast() : rest).contains { $0 == "[" || $0 == "]" }
}

private func emotion(_ raw: ArraySlice<Unicode.Scalar>) -> String {
    let e = text(stripped(raw)).lowercased()
    return emotions.contains(e) ? e : "neutral"
}

/// Remove every feel tag from a complete reply.
public func stripTags(_ reply: String) -> String {
    let s = Array(reply.unicodeScalars)
    var out = Scalars(), i = 0
    while i < s.count {
        if s[i] == "[", let t = tag(s, at: i) { i = t.end } else { out.append(s[i]); i += 1 }
    }
    return text(stripped(out[...]))
}

/// Turns reply deltas into one leading `.feeling`, then tag-free `.delta`s (plus mood shifts).
public struct FeelingFilter {
    private var buf = Scalars()
    private var mood: String?  // nil until the leading Feeling is out
    private var skip = false  // drop one space/newline after the leading tag

    public init() {}

    /// Add a streamed piece of the reply; returns what is ready to show.
    @discardableResult
    public mutating func feed(_ delta: String) -> [Event] {
        buf += delta.unicodeScalars
        return drain(final: false)
    }

    /// The reply is complete: flush what was held back in case it became a tag.
    public mutating func finish() -> [Event] { drain(final: true) }

    private mutating func drain(final: Bool) -> [Event] {
        var out: [Event] = []
        if mood == nil {
            let s = Array(buf.drop(while: { $0.isPySpace }))
            if let t = tag(s, at: 0) {
                buf = Array(s[t.end...])
                skip = true
                mood = emotion(t.raw)
            } else if partial(s[...]) && !final {
                return out
            } else {
                mood = "neutral"
            }
            out.append(.feeling(mood!))
        }
        if skip && !buf.isEmpty {
            if buf[0] == " " || buf[0] == "\n" { buf.removeFirst() }
            skip = false
        }
        return out + body(final: final)
    }

    private mutating func body(final: Bool) -> [Event] {
        var out: [Event] = []
        let b = buf
        var pos = 0, i = 0
        while i < b.count {
            guard b[i] == "[", let t = tag(b, at: i) else { i += 1; continue }
            if i > pos { out.append(.delta(text(b[pos..<i]))) }
            pos = t.end
            i = t.end
            let m = text(stripped(t.raw)).lowercased()
            if emotions.contains(m) && m != mood {
                mood = m
                out.append(.feeling(m))
            }
        }
        let rest = b[pos...]
        let cut = final ? rest.count
            : (rest.indices.first { rest[$0] == "[" && partial(rest[$0...]) }.map { $0 - pos } ?? rest.count)
        if cut > 0 { out.append(.delta(text(rest.prefix(cut)))) }
        buf = Array(rest.dropFirst(cut))
        return out
    }
}
