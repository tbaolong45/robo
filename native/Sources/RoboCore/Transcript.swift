// The conversation shown in the chat window: your turns and Robo's answers, in order. Pure, and in memory only (nothing is written
// to disk). The agent keeps the real history on its side, per Hermes session id (one a day), so this is only what the window displays;
// when the session id changes (a new day, a new persona) the conversation starts again, as the agent's does.
import Foundation

public struct Turn: Equatable, Sendable, Identifiable {
    public enum Role: Sendable { case you, robo }

    public let id: Int
    public let role: Role
    public var text: String
    /// Small lines under a Robo turn: the notes it opened, what the guard recorded of a send.
    public var footer: [String]
    /// The run failed or was stopped: the text is the reason, shown as such.
    public var failed: Bool
    /// The turn is still being written (the typewriter has not finished it).
    public var open: Bool
}

public struct Transcript: Equatable, Sendable {
    /// The most turns kept; the oldest go first.
    public static let cap = 200

    public private(set) var turns: [Turn] = []
    public private(set) var sessionID = ""
    private var next = 1

    public init() {}

    /// A new turn at the end. Robo's turn starts open (it is being typed); yours is complete. Returns its id.
    @discardableResult
    public mutating func append(_ role: Turn.Role, _ text: String, footer: [String] = [], failed: Bool = false) -> Int {
        let id = next
        next += 1
        turns.append(Turn(id: id, role: role, text: text, footer: footer, failed: failed, open: role == .robo))
        trim()
        return id
    }

    /// A line from Robo that is not the answer being written (a local notice such as "Sorry, I didn't catch that"): a finished Robo turn,
    /// placed before the turn being written so that one stays the last.
    @discardableResult
    public mutating func note(_ text: String) -> Int {
        let id = next
        next += 1
        let turn = Turn(id: id, role: .robo, text: text, footer: [], failed: false, open: false)
        if writing { turns.insert(turn, at: turns.count - 1) } else { turns.append(turn) }
        trim()
        return id
    }

    /// The turn being written is dropped when it holds no text (the run was stopped before the first word).
    @discardableResult
    public mutating func dropEmptyLive() -> Bool {
        guard writing, turns[turns.count - 1].text.isEmpty else { return false }
        turns.removeLast()
        return true
    }

    private mutating func trim() {
        if turns.count > Self.cap { turns.removeFirst(turns.count - Self.cap) }
    }

    /// The text of the turn being typed (the last one, when it is Robo's and still open). False when there is none.
    @discardableResult
    public mutating func update(_ text: String) -> Bool {
        guard let i = turns.indices.last, turns[i].role == .robo, turns[i].open else { return false }
        turns[i].text = text
        return true
    }

    /// The last Robo turn is finished: its final text, its footer and whether the run failed.
    @discardableResult
    public mutating func seal(_ text: String, footer: [String] = [], failed: Bool = false) -> Bool {
        guard let i = turns.indices.last, turns[i].role == .robo, turns[i].open else { return false }
        (turns[i].text, turns[i].footer, turns[i].failed, turns[i].open) = (text, footer, failed, false)
        return true
    }

    /// Whether a Robo turn is being written.
    public var writing: Bool { turns.last.map { $0.role == .robo && $0.open } ?? false }

    /// The conversation belongs to one agent session: another id (a new day, a new persona) starts it again. True when turns were dropped.
    @discardableResult
    public mutating func reset(for session: String) -> Bool {
        guard session != sessionID else { return false }
        let dropped = !turns.isEmpty
        turns = []
        sessionID = session
        return dropped
    }
}
