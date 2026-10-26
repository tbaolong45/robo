// The files of the nudges, in robo's data folder (`~/.local/share/robo`, 0700): `agenda.json` (what is coming up, from
// `Agenda.encode`), `nudges.json` (the budget: what was shown today, snoozes, mutes, on/off; `NudgeState`), `reminders.json`
// (which reminders were already shown), `radar.json` (the daily radar: the day of its last run, what it already showed, what it
// offers) and `lms.json` (the LMS scan: its courses and the day each was last scanned). They live here and not in `robo_state.json`, which is shared with the Python build
// and has one key. Every write is atomic (a temp file in the folder, 0600, renamed over the old one), so a crash or a power cut
// leaves the old file or the new one, never half; a file that is missing or unreadable reads as empty.
import Foundation
import RoboCore
import os

/// One thing the radar offers as a nudge, kept (in `radar.json`) until it is shown or `until` passes, so a restart between the run at
/// 07:00 and the 09:00 slot does not lose the day's digest. `note` is relative to the vault ("Radar/2026-10-20.md").
public struct RadarOffer: Codable, Equatable, Sendable {
    public var id: String
    public var category: NudgeCategory
    public var title: String
    public var detail: String
    public var url: String?
    public var note: String?
    public var dueAt: Date?
    public var until: Date

    public init(id: String, category: NudgeCategory, title: String, detail: String, url: String? = nil, note: String? = nil,
                dueAt: Date? = nil, until: Date) {
        (self.id, self.category, self.title, self.detail, self.url, self.note, self.dueAt, self.until) = (id, category, title, detail, url, note, dueAt, until)
    }

    public var candidate: NudgeCandidate {
        NudgeCandidate(id: id, category: category, title: title, detail: detail, url: url, dueAt: dueAt, note: note)
    }
}

/// `radar.json`: the local date of the last finished run, the items it already showed (id -> when; kept 60 days, so a digest never
/// repeats), and the offers that wait for a slot.
public struct RadarState: Codable, Equatable, Sendable {
    public var day = ""
    public var seen: [String: Date] = [:]
    public var offers: [RadarOffer] = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case day, seen, offers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decodeIfPresent(String.self, forKey: .day) ?? ""
        seen = try c.decodeIfPresent([String: Date].self, forKey: .seen) ?? [:]
        offers = try c.decodeIfPresent([RadarOffer].self, forKey: .offers) ?? []
    }
}

/// `lms.json`: the courses the LMS scan knows (names and course page addresses, from the agent's `list` run), the day that list was
/// read, and for each course (by address) the day of its last good scan. What the scans found with a date lives in `agenda.json`; the
/// learning materials (no date) are kept here, so that one is told only once.
public struct LMSState: Codable, Equatable, Sendable {
    public var courses: [LMSPosts.Course] = []
    public var coursesDay = ""
    public var scanned: [String: String] = [:]
    public var materials: [LMSPosts.Material] = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case courses, coursesDay, scanned, materials }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        courses = try c.decodeIfPresent([LMSPosts.Course].self, forKey: .courses) ?? []
        coursesDay = try c.decodeIfPresent(String.self, forKey: .coursesDay) ?? ""
        scanned = try c.decodeIfPresent([String: String].self, forKey: .scanned) ?? [:]
        materials = try c.decodeIfPresent([LMSPosts.Material].self, forKey: .materials) ?? []
    }
}

public struct NudgeFiles {
    private static let log = Logger(subsystem: "ai.robo", category: "nudges")
    /// A fired reminder is forgotten after this long (its item is long past by then).
    public static let keepFired: TimeInterval = 60 * 86_400
    /// The radar forgets an item it showed after this long, and may show it again.
    public static let keepSeen: TimeInterval = 60 * 86_400

    public let dir: URL
    public var agendaFile: URL { dir.appendingPathComponent("agenda.json") }
    public var nudgesFile: URL { dir.appendingPathComponent("nudges.json") }
    public var remindersFile: URL { dir.appendingPathComponent("reminders.json") }
    public var radarFile: URL { dir.appendingPathComponent("radar.json") }
    public var lmsFile: URL { dir.appendingPathComponent("lms.json") }

    public init(dir: URL) { self.dir = dir }

    /// `reminders.json`: the keys of the reminders already shown (`Reminders.key`) with the time each was shown, and whether the
    /// first import of a calendar happened (it marks every event it finds as announced, or the coming week would be "new").
    public struct Fired: Codable, Equatable {
        public var keys: [String: Date] = [:]
        public var imported = false
        public init() {}

        private enum CodingKeys: String, CodingKey { case keys = "fired", imported }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            keys = try c.decodeIfPresent([String: Date].self, forKey: .keys) ?? [:]
            imported = try c.decodeIfPresent(Bool.self, forKey: .imported) ?? false
        }
    }

    // MARK: read

    public func loadAgenda() -> [AgendaItem] { (try? Data(contentsOf: agendaFile)).map(Agenda.decode) ?? [] }

    public func loadNudges() -> NudgeState { (try? Data(contentsOf: nudgesFile)).map(NudgeBudget.decode) ?? NudgeState() }

    /// The fired reminders, without those older than `keepFired` at `now`.
    public func loadFired(now: Date) -> Fired {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var fired = (try? Data(contentsOf: remindersFile)).flatMap { try? decoder.decode(Fired.self, from: $0) } ?? Fired()
        fired.keys = fired.keys.filter { now.timeIntervalSince($0.value) < Self.keepFired }
        return fired
    }

    /// The radar's state, without the items it showed more than `keepSeen` before `now`.
    public func loadRadar(now: Date) -> RadarState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var radar = (try? Data(contentsOf: radarFile)).flatMap { try? decoder.decode(RadarState.self, from: $0) } ?? RadarState()
        radar.seen = radar.seen.filter { now.timeIntervalSince($0.value) < Self.keepSeen }
        return radar
    }

    public func loadLMS() -> LMSState { (try? Data(contentsOf: lmsFile)).flatMap { try? JSONDecoder().decode(LMSState.self, from: $0) } ?? LMSState() }

    // MARK: write

    @discardableResult public func save(_ items: [AgendaItem]) -> Bool { write(Agenda.encode(items), to: agendaFile) }

    @discardableResult public func save(_ lms: LMSState) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(lms) else { return false }
        return write(data, to: lmsFile)
    }

    @discardableResult public func save(_ state: NudgeState) -> Bool { write(NudgeBudget.encode(state), to: nudgesFile) }

    @discardableResult public func save(_ fired: Fired) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(fired) else { return false }
        return write(data, to: remindersFile)
    }

    @discardableResult public func save(_ radar: RadarState) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(radar) else { return false }
        return write(data, to: radarFile)
    }

    /// A failure is a quiet log line with the file's name: the nudges then start from what they had at the next launch, which
    /// costs at most a repeat.
    private func write(_ data: Data, to file: URL) -> Bool {
        do {
            try Self.atomicWrite(data, to: file)
            return true
        } catch {
            Self.log.warning("could not write \(file.lastPathComponent, privacy: .public)")
            return false
        }
    }

    /// The folder is made 0700 if it is missing (like the activity database's); the file is born 0600 as a temp file in that folder
    /// and renamed over the old one, so a crash leaves the old file or the new one. Also used by `FileSecretStore`.
    static func atomicWrite(_ data: Data, to file: URL) throws {
        let dir = file.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString.prefix(8))")
        do {
            try ActivityLog.makePrivateDir(dir)
            guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw ActivityLog.posixFailure()
            }
            guard rename(tmp.path, file.path) == 0 else { throw ActivityLog.posixFailure() }
        } catch {
            unlink(tmp.path)
            throw error
        }
    }
}
