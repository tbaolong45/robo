// What the reply says robo did, against what robo-guard recorded. The guard writes one JSON line per state-changing
// tool call of Hermes (a labelled click, a send key, a file write) to `receipts.jsonl` in robo's data folder: label or
// path, page host, ok. Typed text and page text are never in it, and never in a footer line either.
// A claim ("sent", "đã gửi") with a record gets a "✓" line, a claim without one a "⚠ unverified" line, and a record of a
// step the reply did not name still gets its "✓" line. The lines are the card's footer, a view the reply cannot write to.
import Foundation

/// One receipt: what robo-guard recorded for a tool call.
public struct Evidence: Equatable, Sendable {
    public var tool: String, what: String, host: String, ok: Bool

    public init(tool: String, what: String, host: String = "", ok: Bool = true) {
        (self.tool, self.what, self.host, self.ok) = (tool, what, host, ok)
    }
}

public enum Receipt {
    /// What a claim in the reply is about.
    private enum Act: Hashable { case sent, saved, booked, removed }
    /// What a receipt shows; `wrote` is a file write: it backs "saved" but is no news by itself (the footer already names notes).
    private enum Kind { case sent, saved, wrote, removed }

    private static let options: String.CompareOptions = [.regularExpression, .caseInsensitive]

    // Whole words, so "moved" counts and "removed" does not. Both sides are normalised when matched (é as one scalar, not
    // e + accent) as in Intent. "Sent Items" and "the sent folder" name a place, not an act.
    private static let claims: [(word: String, act: Act, pattern: String)] = [
        ("sent", .sent, #"\bsent\b(?!\s+(?:items?|folder))"#), ("replied", .sent, #"\breplied\b"#),
        ("forwarded", .sent, #"\bforwarded\b"#), ("posted", .sent, #"\bposted\b"#), ("saved", .saved, #"\bsaved\b"#),
        ("booked", .booked, #"\bbooked\b"#), ("scheduled", .booked, #"\bscheduled\b"#),
        ("added to calendar", .booked, #"\badded\s+to\s+(?:the\s+|my\s+|your\s+)?calendar\b"#),
        ("deleted", .removed, #"\bdeleted\b"#), ("moved", .removed, #"\bmoved\b"#),
        ("đã gửi", .sent, #"\bđã\s+gửi\b"#), ("đã lưu", .saved, #"\bđã\s+lưu\b"#), ("đã đặt", .booked, #"\bđã\s+đặt\b"#),
        ("đã xóa", .removed, #"\bđã\s+xóa\b"#), ("đã trả lời", .sent, #"\bđã\s+trả\s+lời\b"#),
    ]

    /// A claim two words after one of these is no claim ("not sent", "to be sent", "once sent", "haven't sent").
    private static let hedges: Set<String> = ["not", "never", "no", "cannot", "without", "be", "if", "unless", "until", "before", "once",
                                              "chưa", "không"]

    /// The button a click named, as the kind of step it takes and a word for it. "Reply" and "Forward" only open the
    /// draft: the step that sends is "Send", so they are not here.
    private static let clicks: [(kind: Kind, word: String, pattern: String)] = [
        (.sent, "sent", #"\b(?:send|post|gửi)\b"#), (.removed, "deleted", #"\b(?:delete|xóa)\b"#),
        (.removed, "moved", #"\b(?:move|junk|spam|archive)\b"#), (.saved, "saved", #"\b(?:save|create|done|schedule)\b"#),
    ]

    /// What went wrong to call it unverified, per claim.
    private static let missing: [Act: String] = [.sent: "send", .saved: "save", .booked: "calendar save", .removed: "delete or move"]

    /// The footer lines for a reply and the receipts of its run: "⚠ unverified: sent (no send was recorded)" for a claim with
    /// none, "✓ sent · outlook.office.com" (×3 for three) for each recorded step; at most 4, the warnings first.
    public static func lines(reply: String, evidence: [Evidence]) -> [String] {
        let steps = evidence.compactMap(step)
        var backed = Set<Int>()
        var warnings: [String] = []
        for (word, act) in claimed(in: reply) {
            let proof = steps.indices.filter { backs(act, steps[$0].kind) }
            if proof.isEmpty { warnings.append("⚠ unverified: \(word) (no \(missing[act]!) was recorded)") }
            backed.formUnion(proof)
        }
        var seen: [(word: String, place: String, count: Int)] = []
        for i in steps.indices where backed.contains(i) || steps[i].kind != .wrote {
            if let at = seen.firstIndex(where: { $0.word == steps[i].word && $0.place == steps[i].place }) {
                seen[at].count += 1
            } else {
                seen.append((steps[i].word, steps[i].place, 1))
            }
        }
        let done = seen.map { "✓ \($0.word)" + ($0.count > 1 ? " ×\($0.count)" : "") + ($0.place.isEmpty ? "" : " · \($0.place)") }
        return Array((warnings + done).prefix(4))
    }

    /// Does a receipt of `kind` back a claim about `act`?
    private static func backs(_ act: Act, _ kind: Kind) -> Bool {
        switch act {
        case .sent: kind == .sent
        case .saved: kind == .saved || kind == .wrote
        case .booked: kind == .saved  // a note is no booking
        case .removed: kind == .removed
        }
    }

    /// What a receipt shows: its kind, a word for it and where (the page's host, or the file's name); nil for a failed call or
    /// one that backs nothing (a computer_use step has no label to read).
    private static func step(_ e: Evidence) -> (kind: Kind, word: String, place: String)? {
        guard e.ok else { return nil }
        switch e.tool {
        case "browser_press":  // the guard only records the keys that send
            return (.sent, "sent", e.host)
        case "write_file", "patch":
            let path = e.what.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            return (.wrote, "saved", URL(fileURLWithPath: path).lastPathComponent)
        case "browser_click":
            let label = e.what.precomposedStringWithCanonicalMapping
            let hit = clicks.first { label.range(of: $0.pattern.precomposedStringWithCanonicalMapping, options: options) != nil }
            return hit.map { ($0.kind, $0.word, e.host) }
        default:
            return nil
        }
    }

    /// The acts the reply claims, in the order it names them, the first word of each.
    private static func claimed(in reply: String) -> [(word: String, act: Act)] {
        let text = reply.precomposedStringWithCanonicalMapping
        var found: [(at: String.Index, word: String, act: Act)] = []
        for claim in claims {
            var from = text.startIndex
            let pattern = claim.pattern.precomposedStringWithCanonicalMapping
            while let hit = text.range(of: pattern, options: options, range: from..<text.endIndex) {
                if !hedged(text[..<hit.lowerBound]) {
                    found.append((hit.lowerBound, claim.word, claim.act))
                    break
                }
                from = hit.upperBound
            }
        }
        var seen = Set<Act>()
        return found.sorted { $0.at < $1.at }.filter { seen.insert($0.act).inserted }.map { ($0.word, $0.act) }
    }

    /// The two words before a claim, in its clause, say it is no claim.
    private static func hedged(_ before: Substring) -> Bool {
        let sentence = before.split(omittingEmptySubsequences: false) { ".!?\n,;:".contains($0) }.last ?? ""
        let words = sentence.lowercased().split { !($0.isLetter || $0 == "'" || $0 == "’") }.suffix(2)
        return words.contains { hedges.contains(String($0)) || $0.hasSuffix("n't") || $0.hasSuffix("n’t") }
    }
}

public enum ReceiptLog {
    /// How many of the last lines of the file are read: a run's receipts are the newest.
    public static let tail = 200

    /// The receipts of `file` written since `since` (unix seconds; the guard's stamps are whole seconds, so the
    /// second `since` falls in counts). A missing file and lines that are not receipts are skipped.
    public static func read(_ file: URL, since: Double) -> [Evidence] {
        struct Row: Decodable { var ts: String, tool: String, label_or_path: String?, host: String?, ok: Bool? }
        guard let data = try? Data(contentsOf: file) else { return [] }
        let stamp = ISO8601DateFormatter()
        return data.split(separator: UInt8(ascii: "\n")).suffix(tail).compactMap { line in
            guard let row = try? JSONDecoder().decode(Row.self, from: Data(line)),
                  let at = stamp.date(from: row.ts)?.timeIntervalSince1970, at >= since.rounded(.down) else { return nil }
            return Evidence(tool: row.tool, what: row.label_or_path ?? "", host: row.host ?? "", ok: row.ok ?? false)
        }
    }
}
