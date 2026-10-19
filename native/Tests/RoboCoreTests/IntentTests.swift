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
