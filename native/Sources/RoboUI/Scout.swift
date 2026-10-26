// The LMS posts scan: deadlines are written in course posts, not in the calendar, so once a day robo asks the agent (skill
// `school-posts`) to read the posts of each course since the last scan, and puts what it finds in the agenda, where the usual
// reminders and the nudge budget take over. The strict half (what a reply may hold, the plan of the day) is `LMSPosts` in RoboCore;
// this is the window's side of it:
//   - OFF until `robo setup` has installed the skill and the profile has a Moodle address (`machine.postsMoodle`), and while the
//     🔔 Nudges chip is off. The first tick after 07:00 local starts the day's first step, one run at a time: the course list (read
//     again every 7 days), then one run per course (the user chose a daily scan and no backfill: a course never scanned reads back
//     one day, a course scanned before reads back to its last good scan).
//   - a run is read-only and unattended: its own session (post text from one course never reaches the next run's context), every
//     approval is denied, 20 minutes at most. It never touches the chat card. A request of the user (typed or spoken) cancels it, and
//     it does not start while a run of the user's is in flight; the next tick goes on.
//   - the reply is decoded strictly (`LMSPosts`): anything that does not pass is dropped and counted, never believed. A failed step is
//     tried again in 30 minutes, three times a day at most; a course that fails does not hold the others up.
//   - the cap `ROBO_DAILY_TOKENS` applies, and every run is logged to `usage.jsonl` like any other.
import AppKit
import RoboCore
import RoboSystem
import os

/// What one run brought back. `cancelled` is the user's own request taking the agent: not a failure.
struct ScoutReply: Sendable {
    var status = "failed"
    var text = ""
    var cancelled = false
    var usage: UsageRecord?
    var steps = 0
    var seconds = 0.0
}

/// One run of the agent, started and watched off the main thread: its events are read here and nowhere else.
final class Scout: @unchecked Sendable {
    static let limitS = 20.0 * 60

    private let hermes: HermesAPI
    private let lock = NSLock()
    private var runID: String?
    private var cancelled = false, timedOut = false

    init(hermes: HermesAPI) { self.hermes = hermes }

    /// The user asked for something: stop the run (now, or as soon as it has an id).
    func cancel() { halt(timedOut: false) }

    private func halt(timedOut late: Bool) {
        let id = lock.withLock { () -> String? in
            if late { timedOut = true } else { cancelled = true }
            return runID
        }
        if let id { Task { [hermes] in try? await hermes.stop(id) } }
    }

    private func started(_ id: String) {
        let stopNow = lock.withLock { () -> Bool in
            runID = id
            return cancelled || timedOut
        }
        if stopNow { Task { [hermes] in try? await hermes.stop(id) } }
    }

    /// Nobody can answer during an unattended run: every ask is denied at once, by its id.
    private func deny(_ id: String) {
        guard let run = lock.withLock({ runID }) else { return }
        Task { [hermes] in try? await hermes.approve(run, .deny, requestId: id) }
    }

    /// Ask the agent `prompt` in a session of its own and wait for the end of the run.
    func run(_ prompt: String, session: String, limit: Double = Scout.limitS) async -> ScoutReply {
        let began = ProcessInfo.processInfo.systemUptime
        var reply = ScoutReply(), streamed = ""
        let watchdog = Task { [self] in
            try? await Task.sleep(for: .seconds(limit))
            if !Task.isCancelled { halt(timedOut: true) }
        }
        do {
            for try await event in hermes.ask(prompt, sessionId: session, started: { [self] id in started(id) }) {
                switch event {
                case .delta(let text): streamed += text
                case .toolStarted: reply.steps += 1
                case .usage(let record): reply.usage = record
                case .approvalNeeded(_, _, let id): deny(id)
                case .runEnded(let status, let output, _):
                    reply.status = status
                    reply.text = output.isEmpty ? streamed : output
                default: break
                }
            }
        } catch {
            reply.status = "failed"
        }
        watchdog.cancel()
        let (userStopped, tooLong) = lock.withLock { (cancelled, timedOut) }
        if userStopped {
            reply.status = "cancelled"
            reply.cancelled = true
        } else if tooLong {
            reply.status = "timed out"
        }
        reply.text = String(reply.text.prefix(200_000))
        reply.seconds = ProcessInfo.processInfo.systemUptime - began
        return reply
    }
}

/// Everything the window keeps about the scan.
struct ScoutModel {
    var state = LMSState()  // lms.json
    var started = false  // the file is read: nothing runs before that
    var running: Scout?  // the run in flight (one at a time)
    var retryAt = 0.0  // wall seconds: a failed step waits until then
    var failures: [String: Int] = [:]  // step key -> failures today (in memory: a restart gives each step its tries again)
    var failureDay = ""
}

enum Posts {
    static let log = Logger(subsystem: "ai.robo", category: "posts")
    static let hour = 7  // the first step of the day starts at the first tick after 07:00 local
    static let retryS = 30.0 * 60  // after a failed step
    static let maxFailures = 3  // a step that failed this often today is left until tomorrow
}

extension RoboWindow {
    /// At launch, once the files are read.
    func loadScout(_ files: NudgeFiles) {
        scout.state = files.loadLMS()
        scout.started = true
    }

    /// From `nudgeTick` (every 30 s of wall time): start the next step of the day when there is one and nothing is in the way.
    func scoutTick(_ now: Date, wall: Double) {
        guard scout.started, scout.running == nil, nudge.state.enabled, wall >= scout.retryAt, !busy, !shutdownStarted,
              let base = machine.postsMoodle(), let host = URL(string: base)?.host() else { return }
        let zone = machine.zone, day = Radar.dayKey(now, zone: zone)
        guard Radar.minutes(now, zone: zone) >= Posts.hour * 60 else { return }
        if scout.failureDay != day { (scout.failures, scout.failureDay) = ([:], day) }
        let skip = Set(scout.failures.filter { $0.value >= Posts.maxFailures }.keys)
        guard let step = LMSPosts.next(courses: scout.state.courses, coursesDay: scout.state.coursesDay, scanned: scout.state.scanned,
                                       today: day, skip: skip) else { return }
        let cap = machine.dailyTokens
        if cap > 0 && Usage.todayTokens(file: machine.usageFile, now: wall) >= cap { return }  // no run starts: it would only cost more
        let prompt: String
        switch step {
        case .list: prompt = LMSPosts.listPrompt
        case .scan(let course, let since): prompt = LMSPosts.scanPrompt(course, since: since, today: day)
        }
        let run = Scout(hermes: hermes)
        scout.running = run
        let (usageFile, bridge, clock) = (machine.usageFile, bridge, machine.wall)
        let session = "robo-posts-\(UUID().uuidString.prefix(8))"
        Task.detached(priority: .utility) {
            let reply = await run.run(prompt, session: session)
            Usage.append(Usage.line(reply.usage, status: reply.status, seconds: reply.seconds, steps: reply.steps, wall: clock()), to: usageFile)
            bridge.scout(step, reply, host: host, day: day)
        }
    }

    /// A step failed: counted, and tried again in half an hour. The log has fixed words, never a course, a post or a reply.
    private func scoutFailed(_ step: LMSPosts.Step, _ why: String) {
        scout.failures[step.key, default: 0] += 1
        scout.retryAt = machine.wall() + Posts.retryS
        Posts.log.notice("posts: \(step == .list ? "the course list" : "a course scan", privacy: .public) failed: \(why, privacy: .public)")
    }

    /// The run is back (main thread).
    func onScout(_ step: LMSPosts.Step, _ reply: ScoutReply, host: String, day: String) {
        scout.running = nil
        if reply.cancelled { return }  // the user asked for something: nothing is counted, the next tick goes on
        guard reply.status == "completed" else { return scoutFailed(step, reply.status == "timed out" ? "timed out" : "the run did not finish") }
        // An agent that says it could not read everything has not scanned: whatever block it left (`[]` built on a refused page is not
        // "nothing new") is not believed, the course is not marked read, and the step is tried again.
        guard !LMSPosts.incomplete(reply.text) else { return scoutFailed(step, "the agent could not read everything") }
        let now = wallDate
        switch step {
        case .list:
            guard case .success(let got) = LMSPosts.courses(in: reply.text, host: host) else { return scoutFailed(step, "no usable reply") }
            scout.state.courses = got.values
            scout.state.coursesDay = day
            let known = Set(got.values.map(\.url))
            scout.state.scanned = scout.state.scanned.filter { known.contains($0.key) }
            nudgeFiles.save(scout.state)
            Posts.log.notice("posts: \(got.values.count, privacy: .public) courses, \(got.dropped, privacy: .public) entries dropped")
        case .scan(let course, _):
            guard case .success(let got) = LMSPosts.items(in: reply.text, host: host, today: now, zone: machine.zone, now: now) else {
                return scoutFailed(step, "no usable reply")
            }
            // A scan reports only the posts since its day and a merge replaces the whole source: what earlier scans found stays,
            // and a thing found again (same course and title) is the new one.
            let old = nudge.agenda, found = Set(got.values.map(\.id))
            nudge.agenda = Agenda.merge(old: old, fresh: old.filter { $0.source == .lms && !found.contains($0.id) } + got.values,
                                        source: .lms, now: now).items
            if nudge.agenda != old { nudgeFiles.save(nudge.agenda) }
            var told = 0
            if case .success(let found) = LMSPosts.materials(in: reply.text, host: host, page: course.url, today: now, zone: machine.zone, now: now) {
                told = tellMaterials(found.values, day: day, now: now)
            }
            scout.state.scanned[course.url] = day
            nudgeFiles.save(scout.state)
            Posts.log.notice("posts: a course scanned, \(got.values.count, privacy: .public) dated items, \(told, privacy: .public) new materials, \(got.dropped, privacy: .public) dropped")
        }
    }

    /// The materials not told before are kept (60 days, 200 at most), listed in the vault note of the day (`Radar/Courses-<day>.md`, all
    /// of the day's scans in it), and offered on the card once a day. Returns how many were new.
    private func tellMaterials(_ found: [LMSPosts.Material], day: String, now: Date) -> Int {
        let known = Set(scout.state.materials.map(\.id))
        let fresh = found.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return 0 }
        let kept = scout.state.materials.filter { $0.firstSeen > now.addingTimeInterval(-60 * 86_400) }
        scout.state.materials = Array((fresh + kept).prefix(200))
        let today = scout.state.materials.filter { Radar.dayKey($0.firstSeen, zone: machine.zone) == day }
        let name = "Courses-\(day).md", folder = Radar.folder(machine.vaultDir)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(RadarNote.materials(day: day, today).utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
        } catch {
            Posts.log.warning("could not write the course materials note")
            return fresh.count
        }
        let cal = Radar.calendar(machine.zone)
        let until = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(2 * 86_400)  // still there tomorrow
        let id = "lms-materials-" + day
        let titles = today.prefix(2).map { RadarNote.short($0.title, 60) }.joined(separator: " · ")
        radar.state.offers = radar.state.offers.filter { $0.id != id } + [RadarOffer(
            id: id, category: .course, title: today.count == 1 ? "1 new course material" : "\(today.count) new course materials",
            detail: titles, note: "Radar/" + name, until: until)]
        nudgeFiles.save(radar.state)
        return fresh.count
    }
}
