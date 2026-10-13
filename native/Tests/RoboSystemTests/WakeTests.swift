// Port of tests/test_wake.py. The login1 source and the clock-gap source are gone (NSWorkspace tells us
// when the Mac wakes), so the FakeSource cases become notifications on a private NotificationCenter and
// the ClockGap cases that are about the user coming back become cases of the wake watcher. Not ported,
// because nothing in Swift can fail that way: a bus error that reconnects, a callback that throws, the
// wake source per OS, and the clock gap that tells a CPU stall or a clock change from a sleep.
import AppKit
import Foundation
import Testing
@testable import RoboSystem

private let D1 = CalendarDay(year: 2026, month: 10, day: 11)!
private let D2 = CalendarDay(year: 2026, month: 10, day: 12)!

private func withTemp<T>(_ body: (URL) throws -> T) rethrows -> T {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("robo-test-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

private func listing(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

private func inode(_ url: URL) -> UInt64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber]) as? NSNumber)!.uint64Value
}

// MARK: - DigestClock

@Test func missingFileIsDue() {
    withTemp { dir in #expect(DigestClock(path: dir.appendingPathComponent("d.json")).due(D1)) }
}

@Test func markThenNotDueSameDayButDueNextDay() throws {
    try withTemp { dir in
        let p = dir.appendingPathComponent("d.json")
        let c = DigestClock(path: p)
        try c.mark(D1)
        #expect(!c.due(D1))
        #expect(c.due(D2))
        #expect(!DigestClock(path: p).due(D1))  // persisted
    }
}

@Test func fileFormatAndPerms() throws {
    try withTemp { dir in
        let p = dir.appendingPathComponent("sub/d.json")
        try DigestClock(path: p).mark(D1)
        // byte for byte what Python's json.dump writes, so either build reads the other's file
        #expect(try Data(contentsOf: p) == Data(#"{"last_digest": "2026-10-11"}"#.utf8))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: p)) as? [String: String]
        #expect(json == ["last_digest": "2026-10-11"])
        let mode = ((try FileManager.default.attributesOfItem(atPath: p.path)[.posixPermissions]) as? NSNumber)!.intValue & 0o7777
        #expect(mode == 0o600)
    }
}

@Test func corruptFileIsDue() throws {
    try withTemp { dir in
        let p = dir.appendingPathComponent("d.json")
        for junk in ["{not json", "[]", #"{"last_digest": 5}"#, #"{"last_digest": "nope"}"#, "", "null",
                     #"{"last_digest": null}"#, #"{"last_digest": "2026-02-30"}"#, #"{"other": "2026-10-11"}"#] {
            try Data(junk.utf8).write(to: p)
            #expect(DigestClock(path: p).due(D1), "\(junk)")
        }
        try Data(#"{"last_digest": "2026-10-11"}"#.utf8).write(to: p)  // the control: a good file is not due
        #expect(!DigestClock(path: p).due(D1))
    }
}

@Test func markIsAtomic() throws {
    try withTemp { dir in
        let p = dir.appendingPathComponent("d.json")
        let c = DigestClock(path: p)
        try c.mark(D1)
        let before = inode(p)
        try c.mark(D2)
        #expect(inode(p) != before)  // a new file renamed over the old one, not the old one rewritten
        #expect(listing(dir) == ["d.json"])  // no tmp left behind
        #expect(!c.due(D2))
    }
}

@Test func aFailedMarkLeavesNoTempFile() throws {
    try withTemp { dir in
        let p = dir.appendingPathComponent("d.json")
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)  // rename onto a directory fails
        #expect(throws: (any Error).self) { try DigestClock(path: p).mark(D1) }
        #expect(listing(dir) == ["d.json"])
    }
}

// MARK: - WakeWatcher

/// A value one thread sets while another reads it.
private final class Locked<T> {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private func wait(_ s: DispatchSemaphore, _ seconds: Double = 2) -> Bool { s.wait(timeout: .now() + seconds) == .success }

/// A watcher on its own NotificationCenter with a clock and an idle time the test moves by hand.
private final class Rig {
    let center = NotificationCenter()
    var awake = 50.0
    var idle = 0.0
    var hits = 0
    lazy var watcher = WakeWatcher({ self.hits += 1 }, center: center, awake: { self.awake }, idle: { self.idle }, poll: 3600)

    init() { watcher.start() }

    /// The Mac wakes now (the notification has been handled when this returns).
    func wake() {
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        watcher.queue.sync {}
    }

    /// One look for the user, as the timer does every `poll` seconds.
    func look() { watcher.queue.sync { watcher.check() } }
}

@Test func resumeCallsBackAndSleepDoesNot() {
    let center = NotificationCenter()
    let woke = DispatchSemaphore(value: 0)
    var hits = 0
    let w = WakeWatcher({ hits += 1; woke.signal() }, center: center, idle: { 0 }, poll: 0.01)
    w.start()
    center.post(name: NSWorkspace.willSleepNotification, object: nil)  // going to sleep
    #expect(!wait(woke, 0.2))
    center.post(name: NSWorkspace.didWakeNotification, object: nil)  // resumed
    #expect(wait(woke))
    w.stop()
    #expect(hits == 1)
}

@Test func stopEndsWatching() {
    let center = NotificationCenter()
    var hits = 0
    let w = WakeWatcher({ hits += 1 }, center: center, idle: { 0 }, poll: 0.01)
    w.stop()  // harmless before start
    w.start()
    w.start()  // and a second start does not subscribe twice
    w.stop()
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    Thread.sleep(forTimeInterval: 0.2)
    w.queue.sync {}
    #expect(hits == 0)
    w.stop()
}

@Test func stopCancelsAWakeStillWaitingForTheUser() {
    let rig = Rig()
    rig.idle = 100
    rig.wake()
    rig.watcher.stop()
    rig.idle = 0
    rig.look()
    #expect(rig.hits == 0)
}

@Test func theUserBeingThereResumesAtOnce() {
    let rig = Rig()
    rig.wake()
    rig.awake += 0.5
    rig.idle = 0.2  // keyboard or mouse after the wake
    rig.look()
    #expect(rig.hits == 1)
    rig.awake += 0.5
    rig.look()
    #expect(rig.hits == 1)  // once per wake
}

@Test func aWakeWithNobodyThereWaitsForTheUser() {
    // Power Nap wakes a shut Mac with nobody there: only input after the wake is a resume.
    let rig = Rig()
    rig.idle = 10_800  // the lid was shut three hours after the last key
    rig.wake()  // a maintenance wake runs robo at 3 am
    for _ in 0..<4 {
        rig.awake += 0.5  // nobody touches the keyboard
        rig.idle += 0.5
        rig.look()
        #expect(rig.hits == 0)
    }
    rig.awake += 0.5
    rig.idle = 0.2  // the user is back and moves the mouse
    rig.look()
    #expect(rig.hits == 1)
    rig.awake += 0.5
    rig.look()
    #expect(rig.hits == 1)  // once per wake
}

@Test func inputFromJustBeforeTheSleepStaysOld() {
    // Idle time may not count the sleep: a key pressed 0.3 s before the lid shut stays 0.3 s old.
    let rig = Rig()
    rig.idle = 0.3
    rig.wake()
    for _ in 0..<4 {
        rig.awake += 0.5
        rig.idle += 0.5
        rig.look()
        #expect(rig.hits == 0)
    }
}

@Test func eachWakeCallsBackOnceAndASecondWakeRestartsTheWait() {
    let rig = Rig()
    rig.idle = 100
    rig.wake()
    rig.awake += 5
    rig.idle += 5
    rig.wake()  // woke again before the user came: the wait starts over
    rig.awake += 1
    rig.idle = 0.5  // input 0.5 s ago, 1 s after the second wake
    rig.look()
    #expect(rig.hits == 1)
    rig.idle = 100
    rig.wake()  // a later sleep
    rig.awake += 1
    rig.idle = 0.5
    rig.look()
    #expect(rig.hits == 2)
}

@Test func itSubscribesToTheRealWorkspaceByDefault() {
    let w = WakeWatcher({})  // NSWorkspace's own center, the real clock and the real idle time
    w.start()
    w.stop()
}

@Test func theTimerFindsTheUserByItself() {
    let center = NotificationCenter()
    let woke = DispatchSemaphore(value: 0)
    let idle = Locked(100.0)  // a dark wake: nobody there; the timer reads it on the watcher's queue
    let w = WakeWatcher({ woke.signal() }, center: center, idle: { idle.value }, poll: 0.01)
    w.start()
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    #expect(!wait(woke, 0.2))
    idle.value = 0  // the user touches the mouse
    #expect(wait(woke))
    w.stop()
}

// MARK: - waitForNetwork

@Test func networkUpAfterRetries() {
    var answers = [false, false, true].makeIterator()
    var slept: [Double] = []
    #expect(waitForNetwork({ answers.next()! }, timeout: 60, interval: 2, sleep: { slept.append($0) }))
    #expect(slept == [2, 2])
}

@Test func networkGivesUpAfterTimeout() {
    var slept: [Double] = []
    #expect(!waitForNetwork({ false }, timeout: 10, interval: 2, sleep: { slept.append($0) }))
    #expect(slept.reduce(0, +) == 10)
}

@Test func probeExceptionCountsAsDown() {
    struct Refused: Error {}
    var answers: [Bool?] = [true, nil]  // taken from the end: the first probe throws
    #expect(waitForNetwork({
        guard let a = answers.removeLast() else { throw Refused() }
        return a
    }, timeout: 10, interval: 1, sleep: { _ in }))
}
