// "Close the chat", read from the sentence's words alone.
import Foundation

public enum Intent {
    // "close the chat": the only spoken way the chat window goes away. The WHOLE sentence must be the request (a few polite words before or
    // after are fine), so "close the browser tab" or "close the chat tab in Safari" are for the agent and never match. English only.
    private static let closeChat = try! NSRegularExpression(
        pattern: #"^(?:(?:hey|ok|okay|robo|please|could you|can you|would you|will you) )*"#
            + #"(?:close|hide|dismiss) (?:the |this |that |my )?(?:chat|conversation)(?: window| panel| box)?"#
            + #"(?: (?:please|now|thanks|thank you|for me))*$"#)

    /// True when the whole sentence asks to close the chat window: "close the chat", "please hide this chat window", "Robo, dismiss the chat."
    public static func closesChat(_ text: String) -> Bool {
        let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        return closeChat.firstMatch(in: words, range: NSRange(location: 0, length: (words as NSString).length)) != nil
    }
}
