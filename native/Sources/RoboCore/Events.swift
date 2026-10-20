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
    /// Hermes' own approval of a computer_use step (click, type, key...) in the user's apps. `id` is its `request_id`:
    /// the answer names it, so it resolves this request and not the oldest one (empty: Hermes sent none).
    case approvalNeeded(String, desktop: Bool = false, id: String = "")
    /// What a completed run cost (`run.completed`'s `usage` and `runtime`), just before its `.runEnded`. A failed, cancelled or
    /// interrupted run carries none: Hermes counts nothing for it.
    case usage(UsageRecord)
    /// `run.completed` / `run.failed` / `run.cancelled` / `run.interrupted`, or a lost stream.
    case runEnded(status: String, output: String = "", error: String = "")

    // Events robo itself produces
    /// The emotion Hermes chose for this reply (its leading `[[feel:x]]` tag).
    case feeling(String)
    /// Robo was called by name (or clicked) and listens (`true`), or stopped (`false`).
    case listening(Bool)
    /// The user sent a message (typed, or the digest button / wake trigger).
    case userSent(String)
    /// A nudge card is about to show (a deadline or an event is near): the feeling to show (as `.feeling`), and robo wakes up
    /// if it was dozing, because the face ignores the emotion of a sleeper.
    case nudged(String)
}
