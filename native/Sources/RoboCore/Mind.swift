// What the face should show: a pure state machine fed Hermes events and clock ticks.
// Port of src/robo/mind.py.

public struct Mind: Equatable, Sendable {
    public static let talkPause = 0.3  // s without a delta before the mouth closes
    public static let flash = 1.5  // s of "concerned" after a tool error
    public static let emotionHold = 8.0  // s an emotion lingers after a reply
    public static let errorHold = 5.0  // s the error face shows before idling
    public static let sleepyAfter = 300.0  // s quiet before sleepy
    public static let asleepAfter = 900.0  // s quiet before asleep

    /// The emotion (and when it ends) to restore when a flash ends.
    public struct After: Equatable, Sendable {
        public var emotion: String
        public var until: Double
    }

    public private(set) var activity = Activity.idle
    public private(set) var emotion = "neutral"
    public private(set) var talking = false
    public private(set) var label = ""
    public private(set) var since: Double  // when the activity began
    public private(set) var lastInput: Double  // last user input or run end: the sleep clock starts here
    public private(set) var emotionUntil = Double.infinity  // emotion reverts to neutral at this time
    public private(set) var lastDelta = 0.0
    public private(set) var after: After?

    /// A fresh, idle mind at `now`.
    public init(now: Double) {
        since = now
        lastInput = now
    }

    // Hermes tool names (~/.hermes/hermes-agent/tools/) -> status label. browser_* -> "browsing…".
    private static let toolLabels = [
        "web_search": "searching the web…",
        "web_extract": "reading a page…",
        "memory": "remembering…",
        "skill_view": "checking a skill…",
        "skills_list": "checking my skills…",
        "skill_manage": "updating a skill…",
    ]

    /// The status line for a Hermes tool name.
    public static func toolLabel(_ tool: String) -> String {
        tool.hasPrefix("browser_") ? "browsing…" : toolLabels[tool] ?? "using \(tool)…"
    }

    private mutating func go(_ a: Activity, _ now: Double) {
        if a != activity { since = now }
        activity = a
    }

    /// Apply one event.
    public func react(_ ev: Event, now: Double) -> Mind {
        var m = self
        switch ev {
        case .userSent:
            m.go(.thinking, now)
            m.emotion = "neutral"; m.emotionUntil = .infinity
            m.label = ""; m.talking = false; m.lastInput = now; m.after = nil
        case .listening(true):
            m.go(.listening, now)
            m.emotion = "neutral"; m.emotionUntil = .infinity
            m.label = "listening…"; m.talking = false; m.lastInput = now; m.after = nil
        case .listening(false) where activity == .listening:
            m.go(.idle, now)
            m.label = ""; m.lastInput = now
        case .toolStarted(let tool):
            m.go(.working, now)
            m.label = Mind.toolLabel(tool)
        case .toolCompleted(_, let error):  // the model reads the result and decides what next
            m.go(.thinking, now)
            m.label = ""
            if error {
                m.after = m.after ?? After(emotion: m.emotion, until: m.emotionUntil)
                m.emotion = "concerned"; m.emotionUntil = now + Mind.flash
            }
        case .feeling(let e) where emotions.contains(e):
            let held = [.idle, .sleepy, .asleep, .error].contains(activity)
            m.emotion = e; m.emotionUntil = held ? now + Mind.emotionHold : .infinity
            m.after = nil
        case .delta:
            m.go(.talking, now)
            m.label = ""; m.talking = true; m.lastDelta = now
        case .approvalNeeded:
            m.go(.waiting, now)
            m.label = ""
        case .runEnded(let status, _, _):
            m.label = ""; m.talking = false; m.lastInput = now
            switch status {
            case "completed":
                m.go(.idle, now)
                m.emotion = after?.emotion ?? emotion  // a flash gives the reply's back
                m.emotionUntil = now + Mind.emotionHold
            case "cancelled":
                m.go(.idle, now)
                m.emotion = "neutral"; m.emotionUntil = .infinity
            default:
                m.go(.error, now)
                m.emotion = status == "interrupted" ? "confused" : "sad"
                m.emotionUntil = now + Mind.errorHold
            }
            m.after = nil
        default:
            break
        }
        return m
    }

    /// Apply the passage of time.
    public func tick(now: Double) -> Mind {
        var m = self
        if m.talking && now >= m.lastDelta + Mind.talkPause { m.talking = false }
        if let a = m.after, now >= m.emotionUntil {
            m.emotion = a.emotion; m.emotionUntil = a.until; m.after = nil
        }
        if m.emotion != "neutral" && now >= m.emotionUntil {
            m.emotion = "neutral"; m.emotionUntil = .infinity
        }
        if m.activity == .error && now >= m.since + Mind.errorHold { m.go(.idle, now) }
        if m.activity == .idle || m.activity == .sleepy {
            if now >= m.lastInput + Mind.asleepAfter {
                m.go(.asleep, now)
            } else if now >= m.lastInput + Mind.sleepyAfter {
                m.go(.sleepy, now)
            }
        }
        return m
    }
}
