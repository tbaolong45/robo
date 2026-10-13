// The vocabulary every robo module shares: what Hermes reports and what the face can show.
// Port of src/robo/events.py.

/// The emotions the face can show; a `.feeling` outside this list is ignored.
public let emotions = [
    "neutral", "happy", "curious", "proud", "concerned", "confused", "playful", "sad", "calm",
]

/// What robo is doing right now; `.asleep` is what `Roamer.step(asleep:)` wants.
public enum Activity: String, CaseIterable, Sendable {
    case idle, listening, thinking, working, talking, waiting, error, sleepy, asleep
}

public enum Event: Equatable, Sendable {
    // Hermes run events (parsed from GET /v1/runs/{id}/events)
    /// A piece of the reply text (`message.delta`).
    case delta(String)
    case toolStarted(String)
    case toolCompleted(tool: String, error: Bool)
    /// Hermes paused the run until the user approves or denies (`approval.request`). `desktop` is
    /// a computer_use step (click, type, key...) in the user's apps.
    case approvalNeeded(String, desktop: Bool = false)
    /// `run.completed` / `run.failed` / `run.cancelled` / `run.interrupted`, or a lost stream.
    case runEnded(status: String, output: String = "", error: String = "")

    // Events robo itself produces
    /// The emotion Hermes chose for this reply (its leading `[[feel:x]]` tag).
    case feeling(String)
    /// Robo was called by name (or clicked) and listens (`true`), or stopped (`false`).
    case listening(Bool)
    /// The user sent a message (typed, or the digest button / wake trigger).
    case userSent(String)
}
