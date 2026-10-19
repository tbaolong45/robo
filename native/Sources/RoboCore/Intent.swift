// What a sentence asks robo to do, read from its words alone. Spoken without the push-to-talk key (a
// follow-up window, which TV or a roommate can fill too), only a request that changes nothing is taken.
import Foundation

public enum Intent {
    // Whole words, so "remove" counts and "removal" does not. "what did she reply" counts too: asking
    // once too often is the safe side. Normalised (é as one scalar, not e + accent) before the match, as
    // String == and NSRegularExpression see the two forms differently.
    private static let writes = try! NSRegularExpression(
        pattern: #"\b(?:"# + [
            "send", "reply", "forward", "submit", "delete", "remove", "erase", "pay", "buy", "purchase", "book", "post",
            "publish", "unsubscribe", "accept", "decline", "rsvp", "upload", "share", "move",
            "gửi", #"trả\s+lời"#, "xóa",
        ].map { $0.precomposedStringWithCanonicalMapping }.joined(separator: "|") + #")\b"#,
        options: .caseInsensitive)

    // A bare "yes" answers a proposal robo made (the digest's "say yes and they go into your calendar"), so
    // hands-free it would act without the key. Only a sentence made of nothing but these counts: "yes, what
    // is due tomorrow" is a question.
    private static let consent: Set<String> = Set(["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "confirm", "proceed", "ahead",
                                                   "do", "có", "ừ", "đồng", "vâng", "dạ"].map { $0.precomposedStringWithCanonicalMapping })
    private static let fillers: Set<String> = Set(["go", "it", "please", "ý"].map { $0.precomposedStringWithCanonicalMapping })

    /// True when `text` talks of sending, replying, deleting, paying, booking, posting, moving and the like,
    /// or is only a "yes" (a confirmation of something robo proposed).
    public static func changesThings(_ text: String) -> Bool {
        let s = text.precomposedStringWithCanonicalMapping
        if writes.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil { return true }
        let words = s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        return !words.isEmpty && words.count <= 5 && words.allSatisfy { consent.contains($0) || fillers.contains($0) }
            && words.contains { consent.contains($0) }
    }
}
