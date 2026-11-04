// Intent.changesThings: the sentences a hands-free follow-up must not act on (the key must be held). Only a clearly read-only
// request passes: the agent runs with every permission, so a miss here would act on what the TV said.
import Testing
@testable import RoboCore

@Test(arguments: [
    // pinned before the rule was inverted
    "send it to Anna", "Reply to Anna with yes.", "forward that to my professor", "Submit the form", "delete the draft",
    "remove her from the invite", "erase it", "pay the invoice", "buy the book", "purchase two tickets",
    "book a room for Friday", "post it in the forum", "publish the page", "unsubscribe me", "accept the invite",
    "Decline the meeting.", "RSVP yes", "upload the file", "share it with Ben", "move it to Friday",
    "what did she reply",  // asks, does not order: over-asking is the safe side
    "SEND IT", "yes, then send.", "ok\u{2014}send",
    // mail
    "email the professor that I'll be late", "mail Anna the slides", "write back to Anna", "draft a reply to the TA",
    "answer Ben's email", "reply all", "forward this to my group", "archive these emails", "mark the email as read",
    "mark all as read", "flag the mail from Anna", "move it to the junk folder", "clear my inbox", "empty the trash",
    "unsubscribe from this newsletter", "trash the spam", "resend the last email", "re-send it", "cc Ben and send it",
    "compose a message to Dr. Lee", "attach the PDF", "save the attachment to my desktop", "block this sender",
    // Teams and chat
    "text Anna I'm running late", "message the group chat", "tell Anna I'll be late", "ask Ben if he has the notes",
    "post my question in the channel", "dm the TA", "ping Ben on Teams", "react with a thumbs up", "join the meeting",
    "leave the group", "mute the channel", "call my mom", "start a call with Ben", "set my status to busy",
    // Moodle and school
    "upload my essay to Moodle", "submit assignment two", "turn in my lab report", "enroll me in the workshop",
    "sign me up for the review session", "register for the exam", "drop the chemistry course", "apply for the internship",
    "start the quiz", "click attempt quiz", "open the quiz and click attempt", "reply to the forum post", "comment on Anna's post",
    "fill in the attendance form", "vote in the poll",
    // calendar
    "cancel my 3pm meeting", "schedule a study session Friday at 4", "reschedule the meeting to Monday", "postpone it a day",
    "add the exam to my calendar", "put the deadline in my calendar", "book office hours with Dr. Lee", "invite Ben to the meeting",
    "set a reminder for 5", "remind me to submit the essay", "remind me to study at 8", "remind me about the exam tomorrow",
    "accept Anna's invite", "decline the 9am", "block Friday afternoon", "move the lecture to Thursday",
    // notes and study plans
    "create a note for chemistry", "make a study plan for next week", "plan my week", "write a summary to my notes",
    "save this to my brain", "rename the note", "delete my old notes", "edit the plan", "update my study plan",
    "change the deadline to Monday", "note that down", "add milk to my list", "copy this to my notes",
    // other
    "order the textbook", "pay for the parking", "download the slides", "print my notes", "install the app",
    "restart my laptop", "run the script",
    // orders dressed as questions or suggestions
    "what if you send it", "What if you just delete it?", "how about emailing her", "how about you cancel it",
    "why don't you book it", "why not post it", "what about texting Anna", "let's cancel it", "let's do it", "let us book it",
    "can you send it", "could you reschedule it", "would you email Anna", "will you post it", "would you mind booking a room",
    "can you please email the professor", "please book a room", "I want you to email Anna", "I need you to post it",
    "I'd like you to text Ben", "is it ok to post it", "is there a way to email her now", "I'll text her later",
    "what's due today and add it to my calendar", "read my mail and then reply to Anna", "summarise it and email it to Ben",
    "find a time and book it", "check my mail and delete the spam", "open the form and fill it in", "check me in for the lab",
    "check it off my list", "have it done by five", "do my homework", "do the reading for me", "tell Ben what's due",
    "give Anna the notes",
    // a question with a write verb: the agent may act on "how do I cancel" as well as answer it
    "can I submit late", "how do I cancel the meeting", "did Anna reply", "what happens if I delete it", "is it too late to apply",
    // Vietnamese, composed and decomposed (g + u + horn + hook above + i)
    "gửi cho cô Lan", "g\u{75}\u{31B}\u{309}i cho cô Lan", "trả lời thư này", "Trả  lời Anna", "xóa email đó", "XÓA nó đi",
    "xoá nó đi", "hủy cuộc họp", "nộp bài tập", "đăng câu hỏi lên diễn đàn", "thêm vào lịch", "vâng, hôm nay có gì",
    // a confirmation answers something robo proposed, alone or before a question
    "yes", "Yes, please.", "ok", "Okay!", "go ahead", "do it", "yeah sure", "Yep, do it please", "confirm", "proceed",
    "có", "ừ", "đồng ý", "vâng", "u\u{31B}\u{300}",  // the last is a decomposed ừ
    "yes what is due tomorrow", "ok what's the time", "sure, read my mail", "sounds good", "that works", "alright then",
    "yes yes yes yes yes yes", "do it later today then please wait here", "go ahead and read my mail",
    // what is not clearly a question or a "show me" is not read-only
    "it", "please", "go", "ahead of schedule", "the sender is Anna", "resend", "payment is due", "booking", "poster", "forwarded",
    "gửia", "never mind", "Anna", "tomorrow at five", "the essay", "PLEASE CANCEL IT", "Cancel. It. Now.",
])
func sentencesThatChangeThings(text: String) {
    #expect(Intent.changesThings(text), "\(text)")
}

@Test(arguments: [
    // pinned before the rule was inverted
    "what is due tomorrow", "what's on my calendar today?", "read my latest mail", "summarise the Moodle page",
    "when is the physics exam", "", "   ", "open the calendar", "?!", "...",
    // whole words only: a noun or a past form inside a question is no order
    "what is the sender's name", "when is the payment due", "show my booking", "is the poster up yet", "show the forwarded mail",
    "what does removal mean", "has Anna sent the slides", "did the professor post the grades yet",
    // mail
    "read my mail", "read the email from Anna", "show me the email from Anna", "any new mail?", "anything from my professor",
    "who emailed me today", "what did the TA say in her email", "summarize my inbox", "how many unread emails do I have",
    "is there anything urgent in my mail", "check my mail", "check my inbox", "find the email about the field trip",
    "search my mail for the lab schedule", "look for the email with the syllabus", "when did Anna email me",
    // Teams and chat
    "what's new in Teams", "any messages from Ben", "show me the Teams chat with my group", "who posted in the class channel",
    "what did the group decide", "is there a meeting link for today", "read the latest post in the channel",
    // Moodle and school
    "what assignments are due this week", "when is the essay due", "what's the deadline for the lab report",
    "list my assignments", "show my grades", "what mark did I get on the quiz", "what grade did I get", "has the grade been posted",
    "is the quiz open yet", "what's new on Moodle", "summarize the course announcements", "explain the feedback on my essay",
    "what does the rubric say", "where is the lecture today", "which room is the exam in", "who teaches chemistry",
    "find the lecture slides for week 3", "look up the room for the exam", "open the Moodle page for physics",
    "what's the answer to question 3", "explain question 3", "how do I get to the library", "describe the project requirements",
    // calendar
    "what's on my schedule tomorrow", "what's on today", "when is my next class", "do I have class tomorrow",
    "am I free on Friday afternoon", "is the library open today", "when is my next call", "what time does the lecture start",
    "when does the exam start", "how long is the lab", "are there any meetings on Monday", "show me next week",
    "what's my day look like", "did the meeting get cancelled", "is the meeting still on", "where is office hours",
    // notes and study plans
    "what's in my study plan", "show my notes on chemistry", "read my plan for today", "what should I study first",
    "how should I prepare for the exam", "what's left to review", "summarize my notes", "find my notes on enzymes",
    "what did I write about the essay", "what's the difference between mitosis and meiosis", "define entropy",
    "translate this into Vietnamese", "compare the two readings", "what is the chain rule", "why is the sky blue",
    "how does photosynthesis work",
    // softer shapes
    "can you show me my schedule", "could you tell me what's due", "would you read it again", "will you explain that",
    "should I study chapter 3 first", "will it rain tomorrow", "could this be wrong",
    "tell me what's due", "give me a summary of the reading", "remind me what's due", "remind me when the exam is",
    "let me know what's due", "let me see the calendar", "I wonder when the exam is", "I want to know what's due",
    "I'd like to know when the lecture is", "do you know when the exam is", "have you seen the new announcement",
    "hey robo what's due", "so what's next on the list", "um when is the exam", "and when is the lab", "please read it again",
    "Robo, what's the time", "WHAT IS DUE TOMORROW", "what   is\ndue tomorrow", "whats due",
    // thanks
    "thanks", "thank you", "thanks robo", "thank you so much", "good morning", "hello",
    // closing the chat is not a request for the agent
    "close the chat",
    // Vietnamese
    "hôm nay có gì", "đọc thư mới nhất", "đọc thư gửia",  // a word that only starts like gửi
    "bài tập nào sắp hết hạn", "khi nào thi", "lịch học ở đâu", "xem lịch hôm nay", "có bài tập mới không", "tóm tắt bài giảng",
])
func sentencesThatChangeNothing(text: String) {
    #expect(!Intent.changesThings(text), "\(text)")
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
