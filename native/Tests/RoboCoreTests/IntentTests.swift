// Intent.closesChat: the whole sentence must ask to close the chat window.
import Testing
@testable import RoboCore

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
    "close the browser tab", "close the window", "close the Teams chat", "close the chat tab in Teams", "close the chat and send it",
    "don't close the chat", "do not close the chat", "never close the chat", "should I close the chat", "why did you close the chat",
    "open the chat", "show the chat", "clear the chat", "close the chats", "disclose the chat", "closed the chat", "enclose the chat",
    "close the chat in my mail", "close the chat with Anna", "what is the chat about", "summarise this chat and close it",
])
func sentencesThatDoNotCloseTheChat(text: String) {
    #expect(!Intent.closesChat(text), "\(text)")
}
