// The LMS scan's side files: `lms.json` (courses, the day each was last scanned: round trip, mode 0600, a missing or damaged file reads
// as empty) and the check that decides whether the scan may run at all (the profile has a Moodle address AND the school-posts skill).
// Only temp folders: no test reads the real data folder or the real Hermes profile.
import Foundation
import RoboCore
import Testing
@testable import RoboSystem

private func tmp() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("robo-lms-\(UUID().uuidString)")
}

@Suite struct LMSStateFileTests {
    private let course = LMSPosts.Course(name: "Linear Algebra (MATH201)", url: "https://moodle.example.edu/course/view.php?id=1234")

    @Test func theStateRoundTripsAndTheFileIsPrivate() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = NudgeFiles(dir: dir)
        #expect(files.loadLMS() == LMSState())  // no file yet
        var state = LMSState()
        state.courses = [course]
        state.coursesDay = "2026-10-20"
        state.scanned = [course.url: "2026-10-20"]
        state.materials = [LMSPosts.Material(id: "lms-material:math201:slides", course: "MATH201", title: "Lecture 5 slides", url: course.url,
                                             posted: "2026-10-20", quote: "Updated File: Lecture 5 slides",
                                             firstSeen: Date(timeIntervalSince1970: 1_792_480_000))]
        #expect(files.save(state))
        #expect(files.loadLMS() == state)
        let mode = try FileManager.default.attributesOfItem(atPath: files.lmsFile.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(folder == 0o700)
        #expect(try String(contentsOf: files.lmsFile, encoding: .utf8).contains("https://moodle.example.edu/course/view.php?id=1234"))  // no \/ escapes
    }

    @Test func aDamagedOrPartialFileReadsAsWhatItHolds() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = NudgeFiles(dir: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json {".write(to: files.lmsFile, atomically: true, encoding: .utf8)
        #expect(files.loadLMS() == LMSState())
        try #"{"coursesDay": "2026-10-20"}"#.write(to: files.lmsFile, atomically: true, encoding: .utf8)
        let partial = files.loadLMS()
        #expect(partial.coursesDay == "2026-10-20" && partial.courses.isEmpty && partial.scanned.isEmpty && partial.materials.isEmpty)
        // the file as it was before materials existed (the live one, 2026-10-22) still reads, and keeps what it had
        try #"{"courses": [{"name": "A", "url": "https://moodle.example.edu/course/view.php?id=1"}], "coursesDay": "2026-10-20", "scanned": {"https://moodle.example.edu/course/view.php?id=1": "2026-10-22"}}"#
            .write(to: files.lmsFile, atomically: true, encoding: .utf8)
        let old = files.loadLMS()
        #expect(old.courses.count == 1 && old.scanned.count == 1 && old.materials.isEmpty)
    }
}

@Suite struct PostsMoodleTests {
    /// A profile in a temp folder; `skill` puts the school-posts skill in it, `env` is the text of its .env.
    private func profile(skill: Bool, env: String?) throws -> (HermesProfile, URL) {
        let root = tmp()
        let p = HermesProfile(home: root.appendingPathComponent("home"), env: ["HERMES_HOME": root.path])
        try FileManager.default.createDirectory(at: p.dir, withIntermediateDirectories: true)
        if let env { try env.write(to: p.dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8) }
        if skill {
            let folder = p.dir.appendingPathComponent("skills/school/school-posts")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\nname: school-posts\n---\n".write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        return (p, root)
    }

    @Test func theScanNeedsTheSkillAndTheAddress() throws {
        for (skill, env, want) in [(true, "MOODLE_BASE_URL=https://moodle.example.edu\n", "https://moodle.example.edu" as String?),
                                   (false, "MOODLE_BASE_URL=https://moodle.example.edu\n", nil),  // `robo setup` has not installed the skill
                                   (true, "", nil), (true, "MOODLE_BASE_URL=\n", nil),  // no address
                                   (true, "MOODLE_BASE_URL=http://moodle.example.edu\n", nil),  // not https
                                   (true, "MOODLE_BASE_URL=--remote-debugging-port=1\n", nil),
                                   (true, nil, nil)] {  // no .env at all
            let (p, root) = try profile(skill: skill, env: env)
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(Setup.postsMoodle(p) == want, "skill \(skill), env \(env ?? "none")")
        }
    }
}
