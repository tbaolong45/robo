// What robo made opening by itself, and the pet's life (the eyes, the moods, the card closing): see AppTests.swift for the helpers.
import AppKit
import Foundation
import Testing
import RoboCore
import RoboSystem
@testable import RoboUI

// MARK: - what robo made opens by itself

@MainActor @Suite(.serialized) struct OpenTests {
    private func request(_ r: Rig, _ text: String = "write me an email") async {
        r.window.ask(text)
        #expect(await pump(!r.window.busy))
    }

    @Test func aNoteRoboWroteOpensInObsidianAndTheCardSaysSo() async {
        let r = Rig([completed("It is in Obsidian.")])
        defer { r.close() }
        let old = r.vault.appendingPathComponent("Notes/old.md")  // made before this request: not reopened
        write([old: "old"], bump: false)
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        let note = r.vault.appendingPathComponent("Drafts/Email to Prof Lee.md")
        r.hermes.onAsk = { write([note: "Hi"]) }
        await request(r)
        #expect(r.notes.map(\.url) == [note] && r.notes.map(\.front) == [true] && r.files.isEmpty)
        #expect(shown(r) == "It is in Obsidian." && r.window.card.footerShown == "📓 In Obsidian: Email to Prof Lee")
    }

    @Test func theAutomaticDigestsNoteOpensBehindWhatYouAreDoing() async {
        let r = Rig([completed("Digest ready.")], digestDue: true)
        defer { r.close() }
        let note = r.vault.appendingPathComponent("Notes/School digest.md")
        r.hermes.onAsk = { write([note: "x"]) }
        #expect(await pump(r.notes.count == 1 && !r.window.busy))
        #expect(r.notes.map(\.front) == [false])
        await request(r, "and the plan?")  // a request of your own opens in front again
        #expect(r.notes.map(\.front) == [false, true])
    }

    @Test func aDigestYouAskForOpensInFront() async {
        let r = Rig([completed("Digest ready.")])
        defer { r.close() }
        let note = r.vault.appendingPathComponent("Notes/School digest.md")
        r.hermes.onAsk = { write([note: "x"]) }
        await request(r, RoboWindow.digestPrompt)  // the right-click Digest entry
        #expect(r.notes.map(\.front) == [true])
    }

    @Test func notesAndPagesShareTheOpenLimitNotesFirst() async {
        let r = Rig([completed("Made.")])
        defer { r.close() }
        let names = ["a.html", "b.html", "c.html"].map { r.out.appendingPathComponent($0) }
            + [r.vault.appendingPathComponent("Notes/n1.md"), r.vault.appendingPathComponent("Plans/n2.md")]
        r.hermes.onAsk = {  // later ones are newer
            let now = Date().timeIntervalSince1970
            for (i, f) in names.enumerated() {
                write([f: "x"], bump: false)
                try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now + Double(i))], ofItemAtPath: f.path)
            }
        }
        await request(r)
        #expect(RoboWindow.openMax == 3)
        #expect(r.notes.map(\.url) == [names[4], names[3]])  // newest first
        #expect(r.files == [names[2]])  // what is left of the limit
        #expect(r.window.card.footerShown == "📓 In Obsidian: n2, n1\n📂 Opened c.html")
    }

    @Test func aFullLimitOfNotesLeavesNoRoomForAPage() async {
        let r = Rig([completed("Made.")])
        defer { r.close() }
        let notes = (0..<4).map { r.vault.appendingPathComponent("Notes/n\($0).md") }
        let page = r.out.appendingPathComponent("page.html")
        r.hermes.onAsk = {
            let now = Date().timeIntervalSince1970
            for (i, f) in ([page] + notes).enumerated() {
                write([f: "x"], bump: false)
                try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now + Double(i))], ofItemAtPath: f.path)
            }
        }
        await request(r)
        #expect(r.notes.map(\.url) == [notes[3], notes[2], notes[1]])  // newest three
        #expect(r.files.isEmpty && !r.window.card.footerShown.contains("📂"))
    }

    @Test func aPageInTheOutputFolderStillOpensAsAFile() async {
        let r = Rig([completed("Here you go.")])
        defer { r.close() }
        let page = r.out.appendingPathComponent("diagram.html")
        let old = r.out.appendingPathComponent("old-notes.html")  // made before this request: not reopened
        write([old: "old"], bump: false)
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        r.hermes.onAsk = { write([page: "<svg/>"]) }
        await request(r)
        #expect(r.files == [page] && r.notes.isEmpty)
        #expect(r.window.card.footerShown == "📂 Opened diagram.html")
    }

    @Test func onlyNotesInTheThreeFoldersOpen() async {
        let r = Rig([completed("Done.")])
        defer { r.close() }
        let stray = [r.vault.appendingPathComponent(".obsidian/plugins/readme.md"),  // Obsidian's own folder
                     r.vault.appendingPathComponent("loose.md"),  // not in Drafts, Plans or Notes
                     r.vault.appendingPathComponent("Notes/data.json")]  // not a note
        r.hermes.onAsk = { write(Dictionary(uniqueKeysWithValues: stray.map { ($0, "x") })) }
        await request(r)
        #expect(r.notes.isEmpty && r.files.isEmpty && r.window.card.footerShown == "")
    }

    @Test func aFailedRequestOpensNothing() async {
        let r = Rig([.event(.runEnded(status: "failed", error: "boom"))])
        defer { r.close() }
        r.hermes.onAsk = {
            write([r.vault.appendingPathComponent("Notes/half.md"): "x", r.out.appendingPathComponent("half.html"): "x"])
        }
        await request(r)
        #expect(r.notes.isEmpty && r.files.isEmpty)
    }

    /// The folders can hold tens of thousands of files: they are read by the worker before the run's end is
    /// reported, never by the end itself on the main thread (so an end with no scan opens nothing).
    @Test func theEndOfARunReadsNoFolderOnTheMainThread() async {
        let r = Rig()
        defer { r.close() }
        write([r.out.appendingPathComponent("page.html"): "x", r.vault.appendingPathComponent("Notes/n.md"): "x"])
        r.window.startedAt = 0  // every file would count as made
        r.window.onEvent(.runEnded(status: "completed", output: "ok"))
        #expect(r.files.isEmpty && r.notes.isEmpty)
    }

    /// Python's Path.is_file() and rglob follow links: a symlinked ~/Robo, a symlinked vault folder and a
    /// symlinked page all count.
    @Test func aSymlinkedOutputFolderIsListed() async throws {
        let r = Rig([completed("Made.")])
        defer { r.close() }
        let real = r.dir.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: r.out, withDestinationURL: real)
        r.hermes.onAsk = { write([r.out.appendingPathComponent("page.html"): "x"]) }
        await request(r)
        #expect(r.files.map(\.lastPathComponent) == ["page.html"])
    }

    @Test func aSymlinkedVaultFolderIsListed() async throws {
        let r = Rig([completed("Made.")])
        defer { r.close() }
        let real = r.dir.appendingPathComponent("notes-elsewhere")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: r.vault, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: r.vault.appendingPathComponent("Notes"), withDestinationURL: real)
        r.hermes.onAsk = { write([r.vault.appendingPathComponent("Notes/n.md"): "x"]) }
        await request(r)
        #expect(r.notes.map(\.url.lastPathComponent) == ["n.md"])
    }

    @Test func aSymlinkedPageIsOpened() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("robo-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.html"), link = dir.appendingPathComponent("latest.html")
        try "x".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(RoboWindow.newest([link], since: 0) == [link])
    }

    @Test func theNewestFilesComeFirstAndAtMostThree() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("robo-newest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = (0..<5).map { dir.appendingPathComponent("f\($0).txt") }
        write(Dictionary(uniqueKeysWithValues: files.map { ($0, "x") }))
        let since = Date().timeIntervalSince1970 - 5
        let got = RoboWindow.newest(files + [dir.appendingPathComponent("missing")], since: since)
        #expect(got == [files[4], files[3], files[2]])
        #expect(RoboWindow.newest(files, since: Date().timeIntervalSince1970 + 100).isEmpty)  // none are new enough
        #expect(RoboWindow.newest([dir], since: 0).isEmpty)  // a folder is not a file
    }
}

// MARK: - alive: the eyes follow the pointer, and a bored robo fidgets

@MainActor @Suite(.serialized) struct AliveTests {
    @Test func theEyesFollowAMovingPointerThenForgetAStillOne() async {
        let r = Rig()
        defer { r.close() }
        let w = r.win
        let c = r.faceMiddle
        r.pointer = CGPoint(x: c.x + 600, y: c.y)  // far to the right
        w.tick()
        #expect((w.face.look?.x ?? 0) > 0.5)  // it moved, so robo looks
        r.clock.advance(Look.stale + 1)  // ...but a pointer that stopped long ago is old news
        w.tick()
        #expect(w.face.look == nil)  // robo is at rest: free glances
    }

    @Test func theEyesLeadTheWayWhileItWalks() async {
        let r = Rig()
        defer { r.close() }
        let w = r.win
        w.tick()
        r.clock.advance(Look.stale + 1)  // the pointer has not moved for a while
        w.roamer.mode = .drift
        w.roamer.goal = w.roamer.pos - Vec(500, 0)
        w.tick()
        #expect((w.face.look?.x ?? 0) < 0)
    }

    @Test func theLookUsesTheFaceWhereverItIsOnTheMainDisplay() async {
        let r = Rig()
        defer { r.close() }
        r.displays = userLayout
        r.window.refit()
        r.window.roamer.hold(now: r.clock.now(), pos: Vec(900, 700))  // away from the corner, on the main display
        r.window.move(to: r.window.roamer.pos)
        let c = r.faceMiddle
        r.pointer = CGPoint(x: c.x - 400, y: c.y)  // left of the face
        r.window.tick()
        #expect((r.window.face.look?.x ?? 0) < -0.3)
        r.pointer = CGPoint(x: c.x + 400, y: c.y)  // right of it: the y-down maths agree
        r.window.tick()
        #expect((r.window.face.look?.x ?? 0) > 0.3)
        r.pointer = CGPoint(x: c.x, y: c.y + 400)  // above it on screen
        r.window.tick()
        #expect((r.window.face.look?.y ?? 0) < -0.3)
    }

    @Test func aBoredRoboNowAndThenShowsAMood() async {
        let r = Rig()
        defer { r.close() }
        r.window.fidgetAt = 0
        r.window.tick()
        #expect(RoboWindow.fidgets.contains(r.window.mind.emotion))
        #expect(r.window.fidgetAt > r.clock.now() + 30)  // and it is a while until the next one
    }

    @Test func aBusyOrTalkedToRoboDoesNotFidget() async {
        let r = Rig()
        defer { r.close() }
        let w = r.win
        w.busy = true
        w.fidgetAt = 0
        w.tick()
        #expect(w.mind.emotion == "neutral")
        w.busy = false
        w.fidgetAt = 0
        w.open()  // the card is up: the user is reading
        w.tick()
        #expect(w.mind.emotion == "neutral")
    }

    @Test func theCardClosesByItselfWhenItsTimeIsUpUnlessTheMouseIsOverIt() async {
        let r = Rig()
        defer { r.close() }
        let w = r.win
        w.open(closeAfter: 20)
        w.closeAt = r.clock.now() - 1  // the reply's time is up
        w.tick()
        #expect(w.card.isHidden && r.frame.size == CGSize(width: 136, height: 104))
        w.open()
        w.closeAt = r.clock.now() - 1
        w.busy = true  // a run is going: the card stays
        w.tick()
        #expect(!w.card.isHidden)
    }
}

