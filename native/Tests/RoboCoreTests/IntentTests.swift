// Intent.changesThings: the sentences a hands-free follow-up must not act on (the key must be held).
import Testing
@testable import RoboCore

@Test(arguments: [
    "send it to Anna", "Reply to Anna with yes.", "forward that to my professor", "Submit the form", "delete the draft",
    "remove her from the invite", "erase it", "pay the invoice", "buy the book", "purchase two tickets",
    "book a room for Friday", "post it in the forum", "publish the page", "unsubscribe me", "accept the invite",
    "Decline the meeting.", "RSVP yes", "upload the file", "share it with Ben", "move it to Friday",
    "what did she reply",  // asks, does not order: over-asking is the safe side
    "SEND IT", "yes, then send.", "ok\u{2014}send",
    // Vietnamese, composed and decomposed (g + u + horn + hook above + i)
    "gửi cho cô Lan", "g\u{75}\u{31B}\u{309}i cho cô Lan", "trả lời thư này", "Trả  lời Anna", "xóa email đó", "XÓA nó đi",
    // a bare confirmation answers something robo proposed, so it must not act hands-free
    "yes", "Yes, please.", "ok", "Okay!", "go ahead", "do it", "yeah sure", "Yep, do it please", "confirm", "proceed",
    "có", "ừ", "đồng ý", "vâng", "u\u{31B}\u{300}",  // the last is a decomposed ừ
])
func sentencesThatChangeThings(text: String) {
    #expect(Intent.changesThings(text))
}

@Test(arguments: [
    "what is due tomorrow", "what's on my calendar today?", "read my latest mail", "summarise the Moodle page",
    "when is the physics exam", "", "   ", "open the calendar",
    "the sender is Anna", "resend", "removal of the old plan", "payment is due", "booking", "poster", "forwarded",  // not whole words
    "hôm nay có gì", "đọc thư mới nhất", "gửia",  // a Vietnamese word that only starts like gửi
    "yes what is due tomorrow", "ok what's the time", "sure, read my mail", "do it later today then please wait here",  // a question, not an answer
    "it", "please", "go", "ahead of schedule", "yes yes yes yes yes yes",  // no consent word, or longer than a short answer
])
func sentencesThatChangeNothing(text: String) {
    #expect(!Intent.changesThings(text))
}

// MARK: closing the chat window

@Test(arguments: [
    "close the chat", "Close the chat.", "CLOSE THE CHAT!", "close chat", "close this chat", "close that chat", "close my chat",
    "close the chat window", "close the chat panel", "close the conversation", "hide the chat", "dismiss the chat", "hide this chat window",
    "please close the chat", "close the chat please", "Please, close the chat now.", "robo close the chat", "Robo, hide the chat window, thanks",
    "hey robo, could you close the chat for me", "ok can you please dismiss the chat thank you", "close   the\nchat",
])
func sentencesThatCloseTheChat(text: String) {
    #expect(Intent.closesChat(text), "\(text)")
}

@Test(arguments: [
    "", "   ", "close", "close it", "hide", "chat", "the chat",  // a bare verb is too vague to act on
    "close the Moodle tab", "close the window", "close the Teams chat", "close the chat tab in Teams", "close the chat and send it",
    "don't close the chat", "do not close the chat", "never close the chat", "should I close the chat", "why did you close the chat",
    "open the chat", "show the chat", "clear the chat", "close the chats", "disclose the chat", "closed the chat", "enclose the chat",
    "close the chat in my mail", "close the chat with Anna", "what is the chat about", "summarise this chat and close it",
])
func sentencesThatDoNotCloseTheChat(text: String) {
    #expect(!Intent.closesChat(text), "\(text)")
}

@Test func closingTheChatIsNotSomethingHandsFreeSpeechIsRefusedFor() {
    // said in the key-less follow-up window it must still work: it changes nothing
    for text in ["close the chat", "hide the chat", "dismiss the chat"] { #expect(!Intent.changesThings(text), "\(text)") }
}
