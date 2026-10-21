// Which reminder of an agenda item is due now. Pure: the clock and the set of keys already fired come in as arguments, and
// the caller (the nudge tick) stores `fired`. The caller should use the wall clock, not a monotonic one that stops in sleep.
//
// The ladder, by kind: deadline T-5 days, T-1 day and T-3 h; exam T-7 days, T-1 day, T-3 h; event (a meeting that is not a class)
// T-30 min; opportunity T-3 days and T-1 day. "A day" is a calendar day in the user's zone (the same wall-clock time the day before,
// also across a DST change); the hours and minutes are absolute. Recurring items (classes) never remind, and nothing in the
// past does. A new or moved item from the calendar feed gets one `newEvent` when it starts within a week, and so does a deadline
// the LMS scan found in a post (within a month).
//
// One item gives at most one reminder at a time. When several rungs are due at once (the app slept, or the item was found
// late) the tightest one is returned and it stands for the looser ones: add `covered` to `fired`, and they never fire later
// (a looser rung is also never due once a tighter one is in `fired`).
// What the rung name says is when it was meant to fire; how long is left is `item.when - now`.
import Foundation

public struct Reminder: Equatable, Sendable {
    public enum Rung: String, Sendable { case week, days5, days3, day, hours3, meeting30, newEvent }

    public var item: AgendaItem
    public var rung: Rung
    /// What the caller records in `fired` once the reminder is shown.
    public var key: String
    /// `key` and the keys of the looser rungs this reminder replaces: all of them go into `fired`.
    public var covered: [String]
    /// The last hours or minutes: shown at once, not at a slot.
    public var urgent: Bool { rung == .hours3 || rung == .meeting30 }
}

public enum Reminders {
    /// How long after an item is first seen it still counts as new.
    public static let newWindow: TimeInterval = 86_400
    /// A new or moved item of the calendar feed is announced when it starts within this long.
    public static let newHorizon: TimeInterval = 7 * 86_400
    /// A deadline the LMS scan read out of a post: teachers give weeks of notice, and the user wants to hear of it at once.
    public static let newHorizonPosts: TimeInterval = 30 * 86_400

    /// The key of one rung of an item. It holds the item's time, so an item that moves (a deadline extended) is reminded afresh.
    /// On the first import of a calendar the caller should add `key(item, .newEvent)` of every item to `fired`, or each
    /// event of the coming week is announced as new.
    public static func key(_ item: AgendaItem, _ rung: Reminder.Rung) -> String {
        "\(item.id)|\(rung.rawValue)|\(Int(item.when.timeIntervalSince1970))"
    }

    private enum Lead { case days(Int), seconds(TimeInterval) }

    /// The rungs of a kind, the longest lead first.
    private static func ladder(_ kind: AgendaItem.Kind) -> [(rung: Reminder.Rung, lead: Lead)] {
        switch kind {
        case .deadline: [(.days5, .days(5)), (.day, .days(1)), (.hours3, .seconds(3 * 3600))]
        case .exam: [(.week, .days(7)), (.day, .days(1)), (.hours3, .seconds(3 * 3600))]
        case .event: [(.meeting30, .seconds(30 * 60))]
        case .opportunity: [(.days3, .days(3)), (.day, .days(1))]
        }
    }

    /// The reminders due at `now`, soonest item first. A rung is due when its time has come and its key is not in `fired`.
    public static func due(items: [AgendaItem], fired: Set<String>, now: Date, zone: TimeZone) -> [Reminder] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        var out: [Reminder] = []
        for item in items.sorted(by: { ($0.when, $0.id) < ($1.when, $1.id) }) where !item.recurring && item.when > now {
            var rungs: [(rung: Reminder.Rung, at: Date)] = []  // the longest lead first
            let isNew = item.changed || now.timeIntervalSince(item.firstSeen) <= newWindow
            let horizon = item.source == .ics ? newHorizon : item.source == .lms ? newHorizonPosts : 0  // the ledger and the radar: never
            if isNew, item.when.timeIntervalSince(now) <= horizon { rungs.append((.newEvent, .distantPast)) }
            for (rung, lead) in ladder(item.kind) {
                switch lead {
                case .days(let n): if let at = cal.date(byAdding: .day, value: -n, to: item.when) { rungs.append((rung, at)) }
                case .seconds(let s): rungs.append((rung, item.when.addingTimeInterval(-s)))
                }
            }
            // A rung is due when its time has come and nothing as tight or tighter has fired: a looser one never follows a tighter one.
            let start = (rungs.lastIndex { fired.contains(key(item, $0.rung)) } ?? -1) + 1
            let ready = rungs[start...].filter { $0.at <= now }
            guard let tightest = ready.last else { continue }
            out.append(Reminder(item: item, rung: tightest.rung, key: key(item, tightest.rung), covered: ready.map { key(item, $0.rung) }))
        }
        return out
    }
}
