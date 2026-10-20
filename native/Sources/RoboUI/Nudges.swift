// Deadline nudges: robo tells you, on its card, what is coming up in your calendar and your study ledger. The pure parts are in
// RoboCore (`ICS`, `Agenda`, `Reminders`, `NudgeBudget`); this file is the window's side of them:
//   - every 45 minutes (and at launch, and after a wake) the calendar links are fetched off the main thread and merged into the
//     agenda; a failed fetch keeps the last good agenda and leaves one quiet log line (never the link)
//   - every 30 s of WALL time (the monotonic clock stops while the Mac sleeps, a deadline does not) the reminders that are due
//     become candidates, and `NudgeBudget.next` decides whether one card shows now (slots, daily cap, quiet hours, ...)
//   - the card never breaks in on anything: it waits while another card, a run, typing, listening, an approval, the follow-up
//     window, the Type window, a mouse press or an absent user (locked, idle over 5 min) holds it
//   - every way the card can end resolves the nudge: a button answers it, anything else (Esc, a click on the face, the minute
//     running out, speaking, a new request) is "dismissed", which never mutes anything
// State is in `agenda.json`, `nudges.json` and `reminders.json` of the data folder (`NudgeFiles`), not in `robo_state.json`.
import AppKit
import RoboCore
import RoboSystem
import os

/// What a calendar refresh found, parsed off the main thread: the events of every link that answered, how many links there
/// are, and why the others failed (no link in it).
struct CalendarRefresh: Sendable {
    var events: [ICSEvent]
    var links: Int
    var failures: [String]
}

/// Everything the window keeps about nudges.
struct NudgeModel {
    var agenda: [AgendaItem] = []
    var state = NudgeState()
    var fired = NudgeFiles.Fired()
    /// What the card shows now, each with the reminder keys it stands for; empty = no nudge is up.
    var shown: [(candidate: NudgeCandidate, covered: [String])] = []
    var checkAt = 0.0, refreshAt = 0.0  // wall seconds: the next check, the next calendar fetch
    var refreshing = false
    var started = false  // the files are read: nothing is written before that
    var ledger: String?  // the study ledger as last read
    var snoozeUntil: Date?  // its "snooze nudges until"
}

/// What the nudge card says: a label, a title, up to three lines, and the domain of the link.
struct NudgeText: Equatable {
    var label: String
    var title: String
    var lines: [String]
    var domain: String?
    var canOpen: Bool

    var body: String { ([title] + lines + (domain.map { ["↗ \($0)"] } ?? [])).joined(separator: "\n") }

    init(_ batch: [NudgeCandidate]) {
        label = batch.allSatisfy { $0.category == .deadline || $0.category == .event } ? "HEADS-UP ▸" : "WORTH A LOOK ▸"
        if let only = batch.first, batch.count == 1 {
            title = only.title
            lines = only.detail.isEmpty ? [] : [only.detail]
            let url = only.url.flatMap(Nudges.openable)
            domain = url?.host()
            canOpen = url != nil || only.note != nil  // a link, or a note of the vault (the radar's digest)
        } else {
            // Several at once make one card: a count, then the first three, each as "what · when".
            title = "\(batch.count) things " + (batch.contains { $0.category == .event } ? "coming up" : "due soon")
            lines = batch.prefix(3).map { c in
                let first = c.detail.split(separator: "\n").first.map(String.init) ?? ""  // an LMS item's quote stays out of the list
                return first.isEmpty ? c.title : "\(c.title) · \(first)"
            }
                + (batch.count > 3 ? ["+ \(batch.count - 3) more"] : [])
            domain = nil
            canOpen = false  // which of them would Open open?
        }
    }
}

enum Nudges {
    static let log = Logger(subsystem: "ai.robo", category: "nudges")
    static let checkS = 30.0  // s of wall time between two looks at the reminders
    static let refreshS = 45.0 * 60  // between two calendar fetches
    static let retryS = 5.0 * 60  // after one that failed (the network is often not back yet right after a wake)
    static let closeS = 60.0  // a nudge card that is not answered closes after this long

    /// The link of a nudge if robo may open it: https only (the same schemes a link in a reply may use).
    static func openable(_ link: String) -> URL? {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme == "https", BoxTextView.schemes.contains(scheme),
              url.host()?.isEmpty == false else { return nil }
        return url
    }

    /// One due reminder as a candidate: its key is the id, the "why" is the time left in words.
    static func candidate(_ r: Reminder, now: Date, zone: TimeZone) -> NudgeCandidate {
        let item = r.item
        let when = whenText(item.when, now: now, zone: zone)
        let category: NudgeCategory
        switch item.kind {
        case .deadline, .exam: category = .deadline
        case .event: category = .event
        case .opportunity: category = .opportunity
        }
        var title = String(item.title.prefix(120))
        if let course = item.course, !title.localizedCaseInsensitiveContains(course) { title = "\(course) · \(title)" }
        var detail = r.rung == .newEvent ? (item.changed ? "moved · " : "new in your calendar · ") + when : when
        // A date an AI read out of a post can be wrong: the card says so and shows the words it was read from.
        if item.source == .lms, let quote = item.quote {
            let head = r.rung == .newEvent ? (item.changed ? "moved · " : "new · ") + when : when  // just found, or a later post moved it
            detail = "\(head)\n“\(quote)”\nfrom a post: check the date"
        }
        return NudgeCandidate(id: r.key, category: category, urgent: r.urgent, title: title, detail: detail, url: item.url, dueAt: item.when)
    }

    /// "in 25 min · 14:00", "in 3 hours · 14:00", "today 18:00", "tomorrow 09:00", "Fri 09:00", "24 Oct 09:00".
    static func whenText(_ when: Date, now: Date, zone: TimeZone) -> String {
        func format(_ pattern: String) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = zone
            f.dateFormat = pattern
            return f.string(from: when)
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let seconds = when.timeIntervalSince(now), clock = format("HH:mm")
        if seconds < 90 * 60 { return "in \(max(1, Int((seconds / 60).rounded(.up)))) min · \(clock)" }
        if seconds < 6 * 3600 { return "in \(Int((seconds / 3600).rounded())) hours · \(clock)" }
        switch cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: when)).day ?? 0 {
        case 0: return "today \(clock)"
        case 1: return "tomorrow \(clock)"
        case 2...6: return "\(format("EEE")) \(clock)"
        default: return "\(format("d MMM")) \(clock)"
        }
    }

    /// The start of the day in the ledger's `snooze nudges until 2026-10-26` (a line of the Notes; the newest is first): nudges
    /// are back that day. nil for none or for a date that does not exist.
    static func snoozeUntil(in ledger: String, zone: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        var inNotes = false
        for raw in ledger.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                inNotes = line.hasPrefix("## ") && line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == "notes"
                continue
            }
            guard inNotes, let found = line.range(of: #"snooze nudges until \d{4}-\d{2}-\d{2}"#, options: [.regularExpression, .caseInsensitive]) else { continue }
            let n = line[found].suffix(10).split(separator: "-").compactMap { Int($0) }
            guard let day = cal.date(from: DateComponents(year: n[0], month: n[1], day: n[2])) else { return nil }
            let back = cal.dateComponents([.month, .day], from: day)  // a day that does not exist comes back as another one
            return back.month == n[1] && back.day == n[2] ? day : nil
        }
        return nil
    }
}

extension RoboWindow {
    var wallDate: Date { Date(timeIntervalSince1970: machine.wall()) }
    var nudgeFiles: NudgeFiles { NudgeFiles(dir: machine.nudgeDir) }

    // MARK: - the agenda

    /// At launch: read the three files, the ledger's exams, and fetch the calendars.
    func startNudges() {
        let files = nudgeFiles, now = wallDate
        nudge.agenda = files.loadAgenda()
        nudge.state = files.loadNudges()
        nudge.fired = files.loadFired(now: now)
        nudge.started = true
        loadRadar(files, now)
        loadScout(files)
        syncLedger(now)
        refreshAgenda()
    }

    /// The Mac woke and the user is back: fetch again and look at the reminders at the next tick.
    func nudgeWoke() {
        nudge.refreshAt = 0
        nudge.checkAt = 0
    }

    /// Fetch every calendar link, off the main thread (the link file, the network and the parse); the answer comes back through
    /// the bridge. One fetch at a time.
    func refreshAgenda() {
        guard nudge.started, !nudge.refreshing else { return }
        nudge.refreshing = true
        nudge.refreshAt = machine.wall() + Nudges.refreshS
        let (fetch, zone, bridge, now) = (machine.calendarBodies, machine.zone, bridge, wallDate)
        Task.detached {
            let got = await fetch()
            let events = got.bodies.flatMap { ICS.parse($0, now: now, zone: zone).events }
            bridge.calendar(CalendarRefresh(events: events, links: got.links, failures: got.failures))
        }
    }

    /// The fetch is back. A failure of any link keeps the agenda as it was (a partial merge would drop the events of the link that
    /// failed) and tries again in 5 minutes; the log line has the labels and the fetcher's fixed words, never a link. The first
    /// successful import marks every event as announced already, or each event of the coming week would be "new in your calendar".
    func onCalendar(_ got: CalendarRefresh) {
        nudge.refreshing = false
        guard got.failures.isEmpty else {
            nudge.refreshAt = machine.wall() + Nudges.retryS
            Nudges.log.notice("calendar refresh failed: \(got.failures.joined(separator: "; "), privacy: .public)")
            return
        }
        let now = wallDate, old = nudge.agenda, oldFired = nudge.fired
        nudge.agenda = Agenda.merge(old: old, fresh: Agenda.fromICS(got.events, now: now), source: .ics, now: now).items
        if got.links == 0 {
            nudge.fired.imported = false  // no link: the next one added is a first import again
        } else if !nudge.fired.imported {
            for item in nudge.agenda where item.source == .ics { nudge.fired.keys[Reminders.key(item, .newEvent)] = now }
            nudge.fired.imported = true
        }
        if nudge.agenda != old { nudgeFiles.save(nudge.agenda) }
        if nudge.fired != oldFired { nudgeFiles.save(nudge.fired) }
    }

    /// The study ledger's exams and its "snooze nudges until", read again when the file changed (it is the agent that writes it).
    func syncLedger(_ now: Date) {
        let text = (try? String(contentsOf: machine.studyFile, encoding: .utf8)) ?? ""
        guard text != nudge.ledger else { return }
        nudge.ledger = text
        nudge.snoozeUntil = Nudges.snoozeUntil(in: text, zone: machine.zone)
        let old = nudge.agenda
        let exams = Agenda.ledgerExams(from: text, zone: machine.zone, now: now)
        nudge.agenda = Agenda.merge(old: old, fresh: exams, source: .ledger, now: now).items
        if nudge.agenda != old { nudgeFiles.save(nudge.agenda) }
    }

    // MARK: - the check

    /// Something that must not be interrupted is going on, or the user is not there.
    var nudgeHeld: Bool {
        !card.isHidden || busy || !approvals.isEmpty || tw.pending || mind.activity == .listening || now() < followUntil
            || typerOpen || press != nil || shutdownStarted || machine.userAway()
    }

    /// Every 30 s of wall time (from `tick`): refresh when it is time, read the ledger, and show what the budget lets through.
    func nudgeTick() {
        let wall = machine.wall(), now = Date(timeIntervalSince1970: wall), zone = machine.zone
        nudge.checkAt = wall + Nudges.checkS
        guard nudge.started else { return }
        if wall >= nudge.refreshAt { refreshAgenda() }
        syncLedger(now)
        radarTick(now, wall: wall)  // the daily radar (Radar.swift): starts its run when due; what it offers joins the candidates below
        scoutTick(now, wall: wall)  // the LMS posts scan (Scout.swift): what it finds joins the agenda, so the reminders below see it
        let due = Reminders.due(items: nudge.agenda, fired: Set(nudge.fired.keys.keys), now: now, zone: zone)
        let offers = radarCandidates(now)
        guard !due.isEmpty || !offers.isEmpty else { return }
        let reminders = due.map { Nudges.candidate($0, now: now, zone: zone) }
        let covered = Dictionary(zip(reminders.map(\.id), due.map(\.covered)), uniquingKeysWith: { first, _ in first })
        var state = nudge.state
        let batch = NudgeBudget.next(state: &state, candidates: reminders + offers, now: now, zone: zone,
                                     ledgerSnoozeUntil: nudge.snoozeUntil, held: nudgeHeld)
        nudge.state = state
        guard !batch.isEmpty else { return }
        nudge.shown = batch.map { ($0, covered[$0.id] ?? []) }  // a radar offer stands for no reminder
        for (_, keys) in nudge.shown { for key in keys { nudge.fired.keys[key] = now } }  // shown: the looser rungs it stands for too
        nudgeFiles.save(nudge.fired)
        nudgeFiles.save(nudge.state)
        // The card may still hold the last answer (closing does not clear it): start from a clean one.
        setHeard("")
        clearReply()
        card.setNudge(NudgeText(batch))
        onEvent(.nudged(batch.contains { $0.category == .deadline } ? "concerned" : "curious"))
        open(closeAfter: Nudges.closeS, askScreen: false)
    }

    // MARK: - the answer

    /// A card button. Open asks first (the same alert as a link in a reply) and a "no" leaves the nudge up.
    func nudgeAnswered(_ outcome: NudgeBudget.Outcome) {
        if outcome == .opened {
            guard nudge.shown.count == 1 else { return }
            let shown = nudge.shown[0].candidate
            if let relative = shown.note {  // the radar's digest or profile: a note of the user's own vault, opened in Obsidian
                guard let note = Radar.noteURL(relative, vault: machine.vaultDir) else { return }
                machine.openNote(note, true)
            } else {
                guard let link = shown.url, let url = Nudges.openable(link), machine.confirmLink(url, "") else { return }
                machine.openURL(url)
            }
        }
        resolveNudge(outcome)
        closeBubble()
    }

    /// The card ended without an answer.
    func dismissNudge() { resolveNudge(.dismissed) }

    /// Tell the budget how the nudge ended, save it and take the nudge off the card. Later gives the reminders back (they were
    /// marked shown when the card came up), and the budget holds them until the next slot.
    func resolveNudge(_ outcome: NudgeBudget.Outcome) {
        guard !nudge.shown.isEmpty else { return }
        let shown = nudge.shown
        nudge.shown = []
        var state = nudge.state
        NudgeBudget.resolve(&state, shown: shown.map(\.candidate), outcome: outcome, now: wallDate, zone: machine.zone)
        nudge.state = state
        if outcome == .later {
            for (_, keys) in shown { for key in keys { nudge.fired.keys[key] = nil } }
            nudgeFiles.save(nudge.fired)
        }
        nudgeFiles.save(nudge.state)
        card.setNudge(nil)
    }

    /// The menu's 🔔 chip: nudges on or off, kept across restarts.
    func toggleNudges() {
        nudge.state.enabled.toggle()
        nudgeFiles.save(nudge.state)
    }
}
