// Port of tests/test_mind.py, plus the fuzz run replayed on Python's own random sequence and
// compared with what the Python state machine did (a digest of every state it passed through).
import Foundation
import Testing
@testable import RoboCore

/// React to events one second apart, starting from a fresh mind at `start`.
private func runMind(_ events: Event..., start: Double = 0) -> (m: Mind, t: Double) {
    var m = Mind(now: start), t = start
    for ev in events {
        t += 1
        m = m.react(ev, now: t)
    }
    return (m, t)
}

extension PyRandom {
    /// Python's `Random.choice`: rejection sampling on `getrandbits(k)`, k = bit length of the count.
    fileprivate mutating func choice<T>(_ items: [T]) -> T {
        let k = Int.bitWidth - items.count.leadingZeroBitCount
        var r: Int
        repeat { r = Int(next32() >> UInt32(32 - k)) } while r >= items.count
        return items[r]
    }
}

/// test_fuzz_stays_in_vocab: 200 runs of 50 random events and ticks. Returns FNV-1a of every state
/// (activity/emotion/talking/label), the visits per activity, and a sum of the clocks.
private func fuzz(seed: UInt64) -> (digest: UInt64, visits: String, clocks: Double, inVocab: Bool) {
    var rng = PyRandom(seed: seed)
    var digest: UInt64 = 0xcbf2_9ce4_8422_2325
    var visits: [String: Int] = [:]
    var clocks = 0.0, inVocab = true
    for _ in 0..<200 {
        var m = Mind(now: 0), t = 0.0
        for _ in 0..<50 {
            t += rng.choice([0.05, 0.5, 3, 10, 400, 1000])
            if rng.random() < 0.7 {
                let ev: Event
                switch rng.choice(Array(0..<7)) {
                case 0: ev = .userSent("x")
                case 1: ev = .toolStarted(rng.choice(["browser_click", "web_search", "zzz", ""]))
                case 2: ev = .toolCompleted(tool: "t", error: rng.random() < 0.5)
                case 3: ev = .feeling(rng.choice(emotions + ["bogus", ""]))
                case 4: ev = .delta("d")
                case 5: ev = .approvalNeeded("a")
                default: ev = .runEnded(status: rng.choice(["completed", "failed", "interrupted", "cancelled", "lost"]))
                }
                m = m.react(ev, now: t)
            } else {
                m = m.tick(now: t)
            }
            inVocab = inVocab && emotions.contains(m.emotion)
            visits[m.activity.rawValue, default: 0] += 1
            clocks += m.since + m.lastInput + m.lastDelta
            for b in "\(m.activity.rawValue)/\(m.emotion)/\(m.talking ? 1 : 0)/\(m.label);".utf8 {
                digest = (digest ^ UInt64(b)) &* 0x100_0000_01b3
            }
        }
    }
    return (digest, visits.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","), clocks, inVocab)
}

@Suite("Mind", .timeLimit(.minutes(1)))
struct MindTests {
    @Test func initialIsIdleNeutral() {
        let m = Mind(now: 5)
        #expect(m.activity == .idle && m.emotion == "neutral" && !m.talking && m.label == "")
        #expect(m.since == 5 && m.lastInput == 5)
    }

    @Test func userSentThinksResetsEmotionAndRecordsInput() {
        var m = Mind(now: 0).react(.feeling("happy"), now: 1)
        m = m.react(.userSent("hi"), now: 2)
        #expect(m.activity == .thinking && m.emotion == "neutral" && m.lastInput == 2 && m.since == 2)
    }

    @Test(arguments: [Activity.sleepy, .asleep])
    func userSentWakes(state: Activity) {
        let m = Mind(now: 0).tick(now: state == .asleep ? 2000 : 400)
        #expect(m.activity == state)
        #expect(m.react(.userSent("hi"), now: 2001).activity == .thinking)
    }

    @Test func toolDoneGoesBackToThinking() {
        let m = runMind(.userSent("x"), .toolStarted("web_search"), .toolCompleted(tool: "web_search", error: false)).m
        #expect(m.activity == .thinking && m.label == "" && m.emotion == "neutral")
    }

    @Test(arguments: [
        ("browser_navigate", "browsing…"), ("browser_click", "browsing…"), ("web_search", "searching the web…"),
        ("web_extract", "reading a page…"), ("memory", "remembering…"), ("skill_view", "checking a skill…"),
        ("frobnicate", "using frobnicate…"),
    ])
    func toolStartedWorksWithLabel(tool: String, label: String) {
        let m = runMind(.userSent("x"), .toolStarted(tool)).m
        #expect(m.activity == .working && m.label == label)
    }

    @Test func toolErrorFlashesConcernedThenContinues() {
        var (m, t) = runMind(.userSent("x"), .toolStarted("web_search"), .toolCompleted(tool: "web_search", error: true))
        #expect(m.activity == .thinking && m.emotion == "concerned")
        m = m.tick(now: t + Mind.flash)
        #expect(m.activity == .thinking && m.emotion == "neutral")
    }

    @Test func toolOkKeepsEmotion() {
        let m = runMind(.userSent("x"), .toolStarted("memory"), .toolCompleted(tool: "memory", error: false)).m
        #expect(m.emotion == "neutral")
    }

    @Test func feelingSetsEmotionAndHoldsDuringRun() {
        let (m, t) = runMind(.userSent("x"), .feeling("curious"))
        #expect(m.emotion == "curious")
        #expect(m.tick(now: t + 1000).emotion == "curious")
    }

    @Test func feelingOutsideVocabIgnored() {
        #expect(runMind(.userSent("x"), .feeling("ecstatic")).m.emotion == "neutral")
    }

    @Test func deltaTalksThenMouthClosesAfterPause() {
        var (m, t) = runMind(.userSent("x"), .delta("hel"))
        #expect(m.activity == .talking && m.talking && m.lastDelta == t)
        #expect(m.tick(now: t + Mind.talkPause - 0.01).talking)
        m = m.tick(now: t + Mind.talkPause)
        #expect(m.activity == .talking && !m.talking)
    }

    @Test func approvalWaits() {
        #expect(runMind(.userSent("x"), .approvalNeeded("rm -rf?")).m.activity == .waiting)
    }

    @Test func completedGoesIdleKeepingEmotionThenDecays() {
        let (m, t) = runMind(.userSent("x"), .feeling("proud"), .delta("done"), .runEnded(status: "completed"))
        #expect(m.activity == .idle && m.emotion == "proud" && !m.talking && m.label == "")
        #expect(m.tick(now: t + Mind.emotionHold - 0.01).emotion == "proud")
        #expect(m.tick(now: t + Mind.emotionHold).emotion == "neutral")
    }

    @Test(arguments: [("failed", "sad"), ("interrupted", "confused")])
    func failureShowsErrorThenIdles(status: String, emotion: String) {
        var (m, t) = runMind(.userSent("x"), .runEnded(status: status, error: "boom"))
        #expect(m.activity == .error && m.emotion == emotion)
        #expect(m.tick(now: t + Mind.errorHold - 0.01).activity == .error)
        m = m.tick(now: t + Mind.errorHold)
        #expect(m.activity == .idle && m.emotion == "neutral")
    }

    @Test func cancelledGoesIdleNeutral() {
        let m = runMind(.userSent("x"), .feeling("happy"), .runEnded(status: "cancelled")).m
        #expect(m.activity == .idle && m.emotion == "neutral")
    }

    @Test func idleGetsSleepyThenAsleep() {
        var m = Mind(now: 0)
        #expect(m.tick(now: Mind.sleepyAfter - 0.01).activity == .idle)
        m = m.tick(now: Mind.sleepyAfter)
        #expect(m.activity == .sleepy)
        #expect(m.tick(now: Mind.asleepAfter - 0.01).activity == .sleepy)
        #expect(m.tick(now: Mind.asleepAfter).activity == .asleep)
    }

    @Test func sleepClockRestartsAfterARun() {
        let (m, t) = runMind(.userSent("x"), .runEnded(status: "completed"), start: 0)
        #expect(m.tick(now: t + Mind.sleepyAfter - 1).activity == .idle)
    }

    @Test(arguments: [Event.toolCompleted(tool: "t", error: false), .toolStarted("w"), .delta("x"), .approvalNeeded("ok?")])
    func neverSleepyMidRun(ev: Event) {
        var (m, t) = runMind(.userSent("x"), ev)
        for dt in [Mind.sleepyAfter, Mind.asleepAfter, 10 * Mind.asleepAfter] {
            m = m.tick(now: t + dt)
            #expect(m.activity != .sleepy && m.activity != .asleep)
        }
    }

    @Test func toolErrorFlashGivesTheReplyEmotionBack() {
        var (m, t) = runMind(.userSent("x"), .feeling("happy"), .toolStarted("web_search"),
                             .toolCompleted(tool: "web_search", error: true))
        #expect(m.emotion == "concerned")
        m = m.tick(now: t + Mind.flash)
        #expect(m.emotion == "happy")
        m = m.react(.runEnded(status: "completed"), now: t + Mind.flash + 1)
        #expect(m.emotion == "happy")
    }

    @Test func runEndingDuringAFlashKeepsTheReplyEmotion() {
        var (m, t) = runMind(.userSent("x"), .feeling("proud"), .toolCompleted(tool: "t", error: true),
                             .runEnded(status: "completed"))
        #expect(m.activity == .idle && m.emotion == "proud")
        m = m.tick(now: t + Mind.emotionHold)
        #expect(m.emotion == "neutral")
    }

    @Test func listeningWakesAndShowsListeningUntilTheTextOrItStops() {
        var m = Mind(now: 0)
        m = m.tick(now: Mind.asleepAfter + 1)
        #expect(m.activity == .asleep)
        let t = Mind.asleepAfter + 2
        m = m.react(.listening(true), now: t)
        #expect(m.activity == .listening && m.emotion == "neutral")
        #expect(m.tick(now: t + Mind.sleepyAfter * 3).activity == .listening)  // never dozes mid-sentence
        #expect(m.react(.userSent("hi"), now: t + 1).activity == .thinking)
        m = m.react(.listening(false), now: t + 2)
        #expect(m.activity == .idle && m.lastInput == t + 2)
    }

    @Test func listeningOffDuringARunChangesNothing() {
        let (m, t) = runMind(.userSent("x"), .toolStarted("web_search"))
        #expect(m.react(.listening(false), now: t + 1).activity == .working)
    }

    /// The Roamer takes `asleep: Bool`; the app derives it from the activity.
    @Test func onlyTheAsleepActivityPutsTheRoamerToBed() {
        let r = Roamer(screens: [Rect(0, 0, 1920, 1080)], size: Vec(120, 120), seed: 4, start: Vec(0, 0))
        let sleepy = Mind(now: 0).tick(now: Mind.sleepyAfter), asleep = Mind(now: 0).tick(now: Mind.asleepAfter)
        _ = r.step(now: 1, asleep: sleepy.activity == .asleep, engaged: false)
        #expect(sleepy.activity == .sleepy && r.mode != .sleep)
        _ = r.step(now: 2, asleep: asleep.activity == .asleep, engaged: false)
        #expect(asleep.activity == .asleep && r.mode == .sleep)
    }

    @Test func eventsCarryPythonsDefaults() {
        #expect(Event.approvalNeeded("x") == .approvalNeeded("x", desktop: false))
        #expect(Event.runEnded(status: "failed") == .runEnded(status: "failed", output: "", error: ""))
    }

    // MARK: golden parity with Python

    /// Python's `random.Random(seed)` drove the same events through robo.mind; its states hash alike.
    @Test(arguments: [
        (UInt64(1234), UInt64(0xa0869dd6652a966a),
         "asleep:152,error:807,idle:743,sleepy:138,talking:1646,thinking:3218,waiting:1646,working:1650", 154522379.64999977),
        (99, 0xb3617f41f324e30e,
         "asleep:167,error:739,idle:681,sleepy:145,talking:1634,thinking:3200,waiting:1742,working:1692", 155084174.24999872),
    ])
    func fuzzStaysInVocabAndMatchesPython(seed: UInt64, digest: UInt64, visits: String, clocks: Double) {
        let got = fuzz(seed: seed)
        #expect(got.inVocab)
        #expect(got.visits == visits)
        #expect(got.digest == digest)
        #expect(abs(got.clocks - clocks) <= 1e-6)
    }
}
