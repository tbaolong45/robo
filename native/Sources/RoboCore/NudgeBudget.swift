// When a nudge may show. Pure: the UI calls `next` on a tick with the candidates it has and shows what comes back, and calls
// `resolve` when the user answers the card. All the state is `NudgeState`, which the caller stores (`nudges.json`).
//
// The rules (times are the user's local time in `zone`):
// - nothing while the app holds (`held`: the card is up, typing, listening...), while nudges are off, during a "snooze nudges
//   until" of the study ledger, or in quiet hours (22:00-08:00)
// - normal nudges only in the slots 09:00, 13:00, 19:00: a slot opens at its time and stays open until the next one, and
//   each slot is used at most once; at most 3 normal nudges a day. All the deadlines and events of one moment are ONE nudge;
//   any other category is a nudge of its own (an opportunity, then new course materials, then the digest, then a contest, one per slot)
// - urgent candidates (the last hours of a deadline, the last minutes before a meeting) show as soon as the app is not held,
//   outside quiet hours, merged into one nudge, and use no slot; at most 4 a day (a fifth waits for a slot like any other)
// - a digest at most once a day (every other day after 3 dismissed in a row); a contest at most once a day and 3 a week; new course
//   materials at most once a day
// - an opportunity only when saved, urgent, or due within 72 hours
// - "Later" snoozes a candidate to the next slot, "Not for me" mutes it for 30 days and, 3 times in a row in one category,
//   mutes the category until the user turns it on (`NudgeState.unmute`); a candidate shown once is not shown again
import Foundation

public enum NudgeCategory: String, Codable, Sendable, CaseIterable {
    case deadline, event, digest, contest, opportunity
    /// New learning materials in a course (the LMS scan): at most one card a day.
    case course
}

/// One thing that could be shown. `id` is stable for the thing (a reminder's key, "digest-2026-10-20", a posting's id).
public struct NudgeCandidate: Equatable, Sendable {
    public var id: String
    public var category: NudgeCategory
    /// The last hours of a deadline or minutes before a meeting (`Reminder.urgent`): shown at once.
    public var urgent: Bool
    public var title: String
    public var detail: String
    public var url: String?
    /// When it is due or starts; a candidate whose time has passed is not shown.
    public var dueAt: Date?
    /// The user saved it (an opportunity): it may nudge before its last 72 hours.
    public var saved: Bool
    /// A note of the vault, relative to it ("Radar/2026-10-20.md"): Open shows it in Obsidian (the radar's digest), instead of opening `url`.
    public var note: String?

    public init(id: String, category: NudgeCategory, urgent: Bool = false, title: String, detail: String = "", url: String? = nil,
                dueAt: Date? = nil, saved: Bool = false, note: String? = nil) {
        (self.id, self.category, self.urgent, self.title, self.detail) = (id, category, urgent, title, detail)
        (self.url, self.dueAt, self.saved, self.note) = (url, dueAt, saved, note)
    }
}

public struct NudgeState: Codable, Equatable, Sendable {
    public var enabled = true
    /// The local date ("2026-10-20") the counters below belong to; they start again on a new date.
    public var day = ""
    public var sentToday = 0
    public var urgentToday = 0
    /// Candidates shown today, by `NudgeCategory.rawValue`.
    public var sentByCategory: [String: Int] = [:]
    /// The hours (9, 13, 19) of the slots used today.
    public var slotsUsed: [Int] = []
    /// The ISO week ("2026-W43") `contestThisWeek` counts.
    public var contestWeek = ""
    public var contestThisWeek = 0
    /// Candidate id -> when "Later" lets it back.
    public var snoozedUntil: [String: Date] = [:]
    /// Candidate id -> when "Not for me" lets it back.
    public var mutedUntil: [String: Date] = [:]
    public var mutedCategories: Set<NudgeCategory> = []
    /// "Not for me" answers in a row, by category (an "Open" starts it again).
    public var notForMeStreak: [String: Int] = [:]
    public var dismissedDigestStreak = 0
    public var lastDigestDay: String?
    /// Candidate id -> when it was shown; kept 60 days.
    public var shown: [String: Date] = [:]

    public init() {}

    /// The user turned a muted category back on.
    public mutating func unmute(_ category: NudgeCategory) {
        mutedCategories.remove(category)
        notForMeStreak[category.rawValue] = 0
    }

    // A file written by an older or newer build still loads: a missing field is its default.
    private enum CodingKeys: String, CodingKey {
        case enabled, day, sentToday, urgentToday, sentByCategory, slotsUsed, contestWeek, contestThisWeek, snoozedUntil
        case mutedUntil, mutedCategories, notForMeStreak, dismissedDigestStreak, lastDigestDay, shown
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        day = try c.decodeIfPresent(String.self, forKey: .day) ?? ""
        sentToday = try c.decodeIfPresent(Int.self, forKey: .sentToday) ?? 0
        urgentToday = try c.decodeIfPresent(Int.self, forKey: .urgentToday) ?? 0
        sentByCategory = try c.decodeIfPresent([String: Int].self, forKey: .sentByCategory) ?? [:]
        slotsUsed = try c.decodeIfPresent([Int].self, forKey: .slotsUsed) ?? []
        contestWeek = try c.decodeIfPresent(String.self, forKey: .contestWeek) ?? ""
        contestThisWeek = try c.decodeIfPresent(Int.self, forKey: .contestThisWeek) ?? 0
        snoozedUntil = try c.decodeIfPresent([String: Date].self, forKey: .snoozedUntil) ?? [:]
        mutedUntil = try c.decodeIfPresent([String: Date].self, forKey: .mutedUntil) ?? [:]
        mutedCategories = try c.decodeIfPresent(Set<NudgeCategory>.self, forKey: .mutedCategories) ?? []
        notForMeStreak = try c.decodeIfPresent([String: Int].self, forKey: .notForMeStreak) ?? [:]
        dismissedDigestStreak = try c.decodeIfPresent(Int.self, forKey: .dismissedDigestStreak) ?? 0
        lastDigestDay = try c.decodeIfPresent(String.self, forKey: .lastDigestDay)
        shown = try c.decodeIfPresent([String: Date].self, forKey: .shown) ?? [:]
    }

    // Written by hand only so that the muted categories are written in a fixed order (a Set has none): the same state is always the same bytes.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(day, forKey: .day)
        try c.encode(sentToday, forKey: .sentToday)
        try c.encode(urgentToday, forKey: .urgentToday)
        try c.encode(sentByCategory, forKey: .sentByCategory)
        try c.encode(slotsUsed, forKey: .slotsUsed)
        try c.encode(contestWeek, forKey: .contestWeek)
        try c.encode(contestThisWeek, forKey: .contestThisWeek)
        try c.encode(snoozedUntil, forKey: .snoozedUntil)
        try c.encode(mutedUntil, forKey: .mutedUntil)
        try c.encode(mutedCategories.map(\.rawValue).sorted(), forKey: .mutedCategories)
        try c.encode(notForMeStreak, forKey: .notForMeStreak)
        try c.encode(dismissedDigestStreak, forKey: .dismissedDigestStreak)
        try c.encodeIfPresent(lastDigestDay, forKey: .lastDigestDay)
        try c.encode(shown, forKey: .shown)
    }
}

public enum NudgeBudget {
    /// How the user answered a card.
    public enum Outcome: Sendable { case opened, later, notForMe, dismissed }

    public static let slots = [9, 13, 19]  // hours
    public static let quietFrom = 22, quietTo = 8  // hours: no nudge from 22:00 to 08:00
    public static let normalPerDay = 3
    public static let urgentPerDay = 4
    public static let contestPerWeek = 3
    public static let opportunityHours = 72.0
    public static let muteDays = 30.0
    static let laterLead = 900.0  // s: Later on something with a time returns this long before it...
    static let laterFloor = 300.0  // ...but not sooner than this from the press
    public static let categoryMuteAfter = 3  // "Not for me" answers in a row
    public static let digestBackoffAfter = 3  // dismissed digests in a row
    static let shownDays = 60.0

    /// The candidates to show now as ONE card, or [] for nothing. Records them as shown in `state`. Call it as often as you
    /// like: between two slots, and once the day's budget is used, it returns [].
    public static func next(state: inout NudgeState, candidates: [NudgeCandidate], now: Date, zone: TimeZone,
                            ledgerSnoozeUntil: Date?, held: Bool) -> [NudgeCandidate] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let today = dayKey(now, cal)
        roll(&state, now: now, today: today, zone: zone)
        guard state.enabled, !held, ledgerSnoozeUntil.map({ $0 <= now }) ?? true else { return [] }
        let time = cal.dateComponents([.hour, .minute], from: now)
        let minutes = (time.hour ?? 0) * 60 + (time.minute ?? 0)
        guard minutes >= quietTo * 60, minutes < quietFrom * 60 else { return [] }

        var seen = Set<String>()
        let live = candidates.filter { c in
            seen.insert(c.id).inserted
                && c.dueAt.map({ $0 > now }) ?? true
                && state.shown[c.id] == nil
                && state.snoozedUntil[c.id].map({ $0 <= now }) ?? true
                && state.mutedUntil[c.id].map({ $0 <= now }) ?? true
                && !state.mutedCategories.contains(c.category)
                && (c.category != .opportunity || c.saved || c.urgent
                    || c.dueAt.map { $0.timeIntervalSince(now) <= opportunityHours * 3600 } ?? false)
        }.sorted { ($0.dueAt ?? .distantFuture, $0.id) < ($1.dueAt ?? .distantFuture, $1.id) }

        func allowed(_ category: NudgeCategory) -> Bool {
            switch category {
            case .digest:
                guard (state.sentByCategory["digest"] ?? 0) < 1 else { return false }
                guard state.dismissedDigestStreak >= digestBackoffAfter, let last = state.lastDigestDay else { return true }
                return (dayGap(last, today) ?? 2) >= 2  // after 3 dismissed: every other day
            case .contest:
                return (state.sentByCategory["contest"] ?? 0) < 1 && state.contestThisWeek < contestPerWeek
            case .course:
                return (state.sentByCategory["course"] ?? 0) < 1
            case .deadline, .event, .opportunity:
                return true
            }
        }
        func record(_ batch: [NudgeCandidate]) {
            for c in batch {
                state.sentByCategory[c.category.rawValue, default: 0] += 1
                state.shown[c.id] = now
                if c.category == .digest { state.lastDigestDay = today }
                if c.category == .contest { state.contestThisWeek += 1 }
            }
        }

        let pool = live.filter { allowed($0.category) }
        let urgent = pool.filter(\.urgent)
        if state.urgentToday < urgentPerDay, !urgent.isEmpty {
            state.urgentToday += 1
            record(urgent)
            return urgent
        }
        // Normal nudges. A fifth urgent candidate is in `pool` and waits for a slot like the rest.
        guard state.sentToday < normalPerDay, let slot = slots.last(where: { $0 * 60 <= minutes }), !state.slotsUsed.contains(slot) else { return [] }
        let groups: [(categories: Set<NudgeCategory>, merged: Bool)] = [([.deadline, .event], true), ([.opportunity], false), ([.course], false), ([.digest], false), ([.contest], false)]
        for (categories, merged) in groups {
            let pick = pool.filter { categories.contains($0.category) }
            guard let first = pick.first else { continue }
            let batch = merged ? pick : [first]
            state.sentToday += 1
            state.slotsUsed.append(slot)
            record(batch)
            return batch
        }
        return []
    }

    /// The user's answer to a card that showed `shown`. Opened: the category's "Not for me" run starts again, and opening a
    /// digest ends the dismissed-digest run. Later: back at the next slot. Not for me: gone for 30 days, and the third in a
    /// row in a category mutes it. Dismissed (the card closed unanswered): only counts against the digest.
    public static func resolve(_ state: inout NudgeState, shown: [NudgeCandidate], outcome: Outcome, now: Date, zone: TimeZone) {
        let categories = Set(shown.map(\.category))
        switch outcome {
        case .opened:
            for c in categories { state.notForMeStreak[c.rawValue] = 0 }
            if categories.contains(.digest) { state.dismissedDigestStreak = 0 }
        case .later:
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            let slot = nextSlot(after: now, cal)
            for c in shown {
                // never past the thing itself: a 10:42 meeting snoozed to the 13:00 slot would be lost (seen live)
                var until = slot
                if let due = c.dueAt { until = min(slot, max(due.addingTimeInterval(-laterLead), now.addingTimeInterval(laterFloor))) }
                state.snoozedUntil[c.id] = until
                state.shown[c.id] = nil
            }
        case .notForMe:
            for c in shown {
                state.mutedUntil[c.id] = now.addingTimeInterval(muteDays * 86_400)
                state.shown[c.id] = nil  // the mute decides when it may come back
            }
            for c in categories {
                let n = (state.notForMeStreak[c.rawValue] ?? 0) + 1
                state.notForMeStreak[c.rawValue] = n
                if n >= categoryMuteAfter { state.mutedCategories.insert(c) }
            }
        case .dismissed:
            if categories.contains(.digest) { state.dismissedDigestStreak += 1 }
        }
    }

    /// The state as JSON (ISO 8601 dates, sorted keys) and back. A file that is not a state gives a fresh one.
    public static func encode(_ state: NudgeState) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? encoder.encode(state)) ?? Data("{}".utf8)
    }

    public static func decode(_ data: Data) -> NudgeState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(NudgeState.self, from: data)) ?? NudgeState()
    }

    // MARK: time

    /// The first slot start after `now`: today's, or tomorrow's 09:00 (computed by the calendar, so DST days are right).
    static func nextSlot(after now: Date, _ cal: Calendar) -> Date {
        let start = cal.startOfDay(for: now)
        for offset in 0...2 {
            guard let day = cal.date(byAdding: .day, value: offset, to: start) else { continue }
            for hour in slots {
                if let at = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day), at > now { return at }
            }
        }
        return now.addingTimeInterval(86_400)
    }

    static func dayKey(_ date: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Days from the date key `a` to `b`; nil when either is not a key.
    static func dayGap(_ a: String, _ b: String) -> Int? {
        func number(_ s: String) -> Int? {
            let p = s.split(separator: "-").compactMap { Int($0) }
            return p.count == 3 ? epochDay(p[0], p[1], p[2]) : nil
        }
        guard let x = number(a), let y = number(b) else { return nil }
        return y - x
    }

    /// A new date or ISO week starts its counters again; what has run out is forgotten.
    private static func roll(_ state: inout NudgeState, now: Date, today: String, zone: TimeZone) {
        if state.day != today {
            state.day = today
            state.sentToday = 0
            state.urgentToday = 0
            state.sentByCategory = [:]
            state.slotsUsed = []
        }
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = zone
        let w = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let week = String(format: "%04d-W%02d", w.yearForWeekOfYear ?? 0, w.weekOfYear ?? 0)
        if state.contestWeek != week {
            state.contestWeek = week
            state.contestThisWeek = 0
        }
        state.snoozedUntil = state.snoozedUntil.filter { $0.value > now }
        state.mutedUntil = state.mutedUntil.filter { $0.value > now }
        state.shown = state.shown.filter { now.timeIntervalSince($0.value) < shownDays * 86_400 }
    }
}
