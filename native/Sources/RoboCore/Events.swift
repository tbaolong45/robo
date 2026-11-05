// The vocabulary every robo module shares: what the agent reports and what the face can show.

/// The emotions the face can show; a `.feeling` outside this list is ignored.
public let emotions = [
    "neutral", "happy", "curious", "proud", "concerned", "confused", "playful", "sad", "calm",
]

/// What robo is doing right now; `.asleep` is what `Roamer.step(asleep:)` wants.
/// `.working` and `.waiting` are unreachable now (no tools, no approvals); the face's tables and goldens still hold them.
public enum Activity: String, CaseIterable, Sendable {
    case idle, listening, thinking, working, talking, waiting, error, sleepy, asleep
}

public enum Event: Equatable, Sendable {
    // Agent run events (parsed from GET /v1/runs/{id}/events)
    /// A piece of the reply text (`message.delta`).
    case delta(String)
    /// `run.completed` / `run.failed` / `run.cancelled`, or a lost stream.
    case runEnded(status: String, output: String = "", error: String = "")

    // Events robo itself produces
    /// The emotion the agent chose for this reply (its leading `[[feel:x]]` tag).
    case feeling(String)
    /// Robo was called by name (or clicked) and listens (`true`), or stopped (`false`).
    case listening(Bool)
    /// The user sent a message (typed or spoken).
    case userSent(String)
}
