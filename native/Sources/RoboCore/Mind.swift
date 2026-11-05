// What the face should show: a pure state machine fed agent events and clock ticks.

public struct Mind: Equatable, Sendable {
    public static let talkPause = 0.3  // s without a delta before the mouth closes
    public static let emotionHold = 8.0  // s an emotion lingers after a reply
    public static let errorHold = 5.0  // s the error face shows before idling
    public static let sleepyAfter = 300.0  // s quiet before sleepy
    public static let asleepAfter = 900.0  // s quiet before asleep

    public private(set) var activity = Activity.idle
    public private(set) var emotion = "neutral"
    public private(set) var talking = false
    public private(set) var since: Double  // when the activity began
    public private(set) var lastInput: Double  // last user input or run end: the sleep clock starts here
    public private(set) var emotionUntil = Double.infinity  // emotion reverts to neutral at this time
    public private(set) var lastDelta = 0.0

    /// A fresh, idle mind at `now`.
    public init(now: Double) {
        since = now
        lastInput = now
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
            m.talking = false; m.lastInput = now
        case .listening(true):
            m.go(.listening, now)
            m.emotion = "neutral"; m.emotionUntil = .infinity
            m.talking = false; m.lastInput = now
        case .listening(false) where activity == .listening:
            m.go(.idle, now)
            m.lastInput = now
        case .feeling(let e) where emotions.contains(e):
            let held = [.idle, .sleepy, .asleep, .error].contains(activity)
            m.emotion = e; m.emotionUntil = held ? now + Mind.emotionHold : .infinity
        case .delta:
            m.go(.talking, now)
            m.talking = true; m.lastDelta = now
        case .runEnded(let status, _, _):
            m.talking = false; m.lastInput = now
            switch status {
            case "completed":
                m.go(.idle, now)
                m.emotionUntil = now + Mind.emotionHold
            case "cancelled":
                m.go(.idle, now)
                m.emotion = "neutral"; m.emotionUntil = .infinity
            default:
                m.go(.error, now)
                m.emotion = "sad"
                m.emotionUntil = now + Mind.errorHold
            }
        default:
            break
        }
        return m
    }

    /// Apply the passage of time.
    public func tick(now: Double) -> Mind {
        var m = self
        if m.talking && now >= m.lastDelta + Mind.talkPause { m.talking = false }
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
