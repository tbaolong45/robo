// What a sentence asks robo to do, read from its words alone. Spoken without the push-to-talk key (a
// follow-up window, which TV or a roommate can fill too), only a request that changes nothing is taken.
import Foundation

public enum Intent {
    private static func words(_ list: String) -> Set<String> {
        Set(list.split(separator: " ").map { String($0).precomposedStringWithCanonicalMapping })
    }

    // Verbs that order a change wherever they stand ("what if you send it", "and then delete it"), with their -ing forms
    // ("how about cancelling it"). Base forms only otherwise: an order uses them, a question about the past mostly does not
    // ("has Anna sent it", "the forwarded mail"). "what did she reply" counts: asking once too often is the safe side.
    private static let writes: Set<String> = {
        let base = words("""
            send resend forward reply respond submit resubmit delete remove erase wipe discard cancel pay buy purchase unsubscribe \
            subscribe accept decline reject approve deny rsvp upload publish rename archive unarchive enroll enrol unenroll register \
            withdraw transfer install uninstall trash unflag mute unmute block unblock reschedule postpone edit modify overwrite \
            replace create add insert append attach save compose sign join confirm click press paste execute launch quit restart \
            reset restore undo dm notify assign unassign sync vote unfollow move apply dismiss
            """)
        return withIng(base)
    }()
    private static func withIng(_ base: Set<String>) -> Set<String> {  // over-made forms ("sening") are harmless
        base.union(base.flatMap { v in [v + "ing", String(v.dropLast()) + "ing", v + String(v.last!) + "ing"] })
    }
    // As often nouns as verbs ("read the post", "my schedule", "the answer to question 3"): an order only right after a word
    // that leads into a verb ("is it ok to post it", "and then email Anna", "I'll text her", "would you mind booking it"). At
    // the start of a sentence the shape test below already refuses them.
    private static let maybeWrites = withIng(words("""
        answer ask book call change clear copy comment download draft drop email fill finish fix flag get give invite leave lock \
        mail make mark message note order pin plan post print put report run schedule set share start stop tell text turn \
        type update write
        """))
    private static let leadsToVerb = words("to and then also or please just now can could will would should shall must ll mind about try keep")

    // A sentence that is only thanks or a greeting changes nothing (nothing in it agrees to a proposal).
    private static let pleasantries = words("thanks thank you so much very hello hi hey robo bye goodbye good morning afternoon evening night cheers")
    private static let greetings = words("thanks thank hello hi bye goodbye morning afternoon evening night cheers")

    // Dropped from the front before the shape test. Not "yes" or "ok": after robo proposed something ("say yes and they go
    // into your calendar") a sentence that starts with a yes may be taken as one by the agent.
    private static let lead = words("hey hi hello robo so um uh uhm er oh well and also now then just quickly please kindly actually wait")
    // The words a read-only request starts with: a question, or an order to show or tell something.
    private static let asks = words("""
        what whats when where who whom whose which how why is are was were am isn aren wasn weren does did doesn didn has hasn had \
        any anything anyone anybody show list read explain summarize summarise describe define translate find search look see \
        open display view compare recap
        """)
    private static let modals = words("can could will would should shall may might must")
    private static let subjects = words("i we they he she it there this that these those my our your the anyone anybody someone anything something")
    private static let qwords = words("what when where who which how why whether if")

    // "close the chat": the only way the chat window goes away. The WHOLE sentence must be the request (a few polite words before or after
    // are fine), so "close the Moodle tab" or "close the chat tab in Teams" are for the agent and never match. English only.
    private static let closeChat = try! NSRegularExpression(
        pattern: #"^(?:(?:hey|ok|okay|robo|please|could you|can you|would you|will you) )*"#
            + #"(?:close|hide|dismiss) (?:the |this |that |my )?(?:chat|conversation)(?: window| panel| box)?"#
            + #"(?: (?:please|now|thanks|thank you|for me))*$"#)

    /// True when the whole sentence asks to close the chat window: "close the chat", "please hide this chat window", "Robo, dismiss the chat."
    public static func closesChat(_ text: String) -> Bool {
        let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        return closeChat.firstMatch(in: words, range: NSRange(location: 0, length: (words as NSString).length)) != nil
    }

    /// False only for a request that is clearly read-only: a question ("what is due tomorrow", "has the grade been posted?"), an
    /// order to show, read, find or explain something ("summarise the Moodle page"), thanks, or "close the chat". Everything
    /// else is taken to change something and needs the key when spoken hands-free: any write verb ("cancel", "what if you send
    /// it"), an order of any other kind ("email the professor", "schedule a session"), a "yes"/"ok"/"go ahead", and what this
    /// cannot read, which includes every language but English (the owner speaks English to Robo, and Parakeet only hears that). Empty text is false (there is nothing to refuse).
    public static func changesThings(_ text: String) -> Bool {
        let s = text.precomposedStringWithCanonicalMapping.lowercased()
        let w = s.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        if w.isEmpty || closesChat(text) { return false }
        let line = " " + w.joined(separator: " ") + " "
        if w.contains(where: writes.contains) { return true }
        for (before, word) in zip(w, w.dropFirst()) where maybeWrites.contains(word) && leadsToVerb.contains(before) { return true }
        if line.contains(" let s ") || line.contains(" let us ") { return true }  // "let's book it"
        if w.allSatisfy(pleasantries.contains) && w.contains(where: greetings.contains) { return false }
        return !asksOnly(Array(w.drop { lead.contains($0) }))
    }

    /// The sentence (fillers dropped) has the shape of a question or of "show/tell me": what it starts with decides.
    private static func asksOnly(_ w: [String]) -> Bool {
        var w = w
        while w.count >= 2 && ["can", "could", "would", "will"].contains(w[0]) && w[1] == "you" {  // "can you show me" = "show me"
            w.removeFirst(w.count > 2 && w[2] == "mind" ? 3 : 2)
            w = Array(w.drop { lead.contains($0) })
        }
        guard let first = w.first else { return false }
        let second = w.count > 1 ? w[1] : "", third = w.count > 2 ? w[2] : ""
        if ["what if", "how about", "what about", "why don", "why not"].contains(first + " " + second) { return false }  // a suggestion
        switch first {
        case "tell", "give": return second == "me" || second == "us"  // "tell Anna I'm late" sends a message
        case "remind": return second == "me" && qwords.contains(third)  // "remind me what's due", not "remind me to study"
        case "check": return second != "in" && second != "off" && third != "in" && third != "off"  // not "check me in"
        case "do": return ["i", "you", "we", "they"].contains(second)  // "do I have class", not "do it"
        case "have": return ["i", "you", "we", "they", "anyone", "anybody"].contains(second)  // not "have it done by five"
        case "let": return second == "me" && (third == "know" || third == "see")
        case "i": return ["i wonder", "i want to know", "i need to know", "i d like to know", "i would like to know"]
            .contains { (w.joined(separator: " ") + " ").hasPrefix($0 + " ") }
        default: return modals.contains(first) ? subjects.contains(second) : asks.contains(first)
        }
    }
}
