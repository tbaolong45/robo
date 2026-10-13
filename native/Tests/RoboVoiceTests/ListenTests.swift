// Port of tests/test_listen.py: the name matcher, the endpointer and the Listener state machine, driven
// with synthetic sample arrays. No test opens the microphone or loads the speech model.
import Foundation
import Testing
@testable import RoboVoice

let speech: Float = 0.3

/// A mic frame at `level` whose first sample tags it with its stream index `i`.
func frame(_ i: Int, _ level: Float = 0) -> [Float] {
    var f = [Float](repeating: level, count: Listen.frame)
    f[0] = Float(i) * 1e-4
    return f
}

/// The stream indexes of the frames in `audio` (inverse of `frame`).
func tags(_ audio: [Float]) -> [Int] {
    stride(from: 0, to: audio.count, by: Listen.frame).map { Int((audio[$0] * 1e4).rounded()) }
}

func frames(_ a: Int, _ b: Int, _ level: Float = 0) -> [[Float]] { (a..<b).map { frame($0, level) } }

// MARK: - addressed

@Test(arguments: [
    ("Robo, what time is it?", "what time is it?"),
    ("Hey Robo, what's on my calendar today?", "what's on my calendar today?"),
    ("What's due this week, robo?", "What's due this week"),
    ("Can robo open Moodle for me", "Can robo open Moodle for me"),
    ("Robot, open Moodle.", "open Moodle."),
    ("ok Robo.", ""),
    ("Yo robbo. What time is it?", "What time is it?"),
    // what Parakeet TDT v2 wrote for the user's own "robo" (recorded 2026-10-11)
    ("Rubo opened mail.", "opened mail."),
    ("High robot check models.", "check models."),
    ("Ok Rubo Blameday.", "Blameday."),
    ("Rubo, tell me a joke.", "tell me a joke."),
    ("Rubo.", ""),
    ("Robot draft an email my professor.", "draft an email my professor."),
    ("Rubo, what's weather? Thanks, Rubo.", "what's weather? Thanks"),
    // second, held-out recording
    ("Roombo search timer for 10 minutes.", "search timer for 10 minutes."),
    ("Hi Robo read my latest.", "read my latest."),
    ("Can you help me, Robo?", "Can you help me"),
    ("Rubble play mode.", "play mode."),
    ("Robbo play mode.", "play mode."),
    // Parakeet glues a greeting to the name: "Yo robo, ..." came out as "Yorobo, ..."
    ("Yorobo, open my calendar.", "open my calendar."),
    ("Heyrobo what's due this week?", "what's due this week?"),
    ("Okayrobo.", ""),
    // regex dialect: what Python's re gives for these (Unicode \w and \b, "$" before a final newline)
    ("Robo.\n", ""), ("\nRobo, hi", "hi"), ("Hey\u{a0}Robo, go", "go"), ("über Robo", "über"),
    ("a.\nrobo", "a"), ("robo\u{2028}", ""), ("Robo \n over", "over"), ("Robo, \u{2026}over\u{2026}", "over\u{2026}"),
])
func sentencesThatCallRobo(text: String, said: String) {
    #expect(addressed(text) == said)
}

@Test(arguments: [
    "I'm studying linear algebra tonight.", "Robert called", "the robot vacuum is broken",
    "I'm going to show you how to do this.", "", "you",
    // the user's own sentences without the name (Parakeet transcripts)
    "Robots are interesting.", "Let's go over notes.", "I need study calculus tonight.",
    "The letter was long today.", "Can you pass me water?", "Ruby on rails is fun",
    "My friend bought a ro robot.", "Rob is coming over tonight. The robot.",
    "Ralph is coming over tonight, the robots.", "The house was rubble", "Robert called.",
    // words that start like "greeting + name" once the space between them may be missing
    "Hirobumi Ito was a statesman.", "Hiring robots is hard.", "Hiroshima is a city.",
    "Okay so the robot vacuum is loud.", "Yoruba is a language.",
    "\u{ff52}\u{ff4f}\u{ff42}\u{ff4f} hello", "Robo\u{663}", "\u{130}robo",  // full-width, Arabic digit, dotted I
])
func sentencesNotForRobo(text: String) {
    #expect(addressed(text) == nil)
}

// MARK: - Endpointer, speech gate, levelling

/// 1-based frame at which the Endpointer says the utterance ended (frames of 0.25 s).
func endsAt(_ levels: [Double], frameS: Double = 0.25, gate: Double = 0.1) -> Int? {
    var ep = Endpointer(gate: gate, frameS: frameS)
    return levels.enumerated().first { ep.feed($0.element) }.map { $0.offset + 1 }
}

let loud = Double(speech)

@Test func endsAfterMostOfASecondOfSilenceAfterSpeech() {
    #expect(endsAt([loud, loud] + [Double](repeating: 0, count: 10)) == 2 + 3)  // 0.75 s >= END_SILENCE_S
}

@Test func shortPauseDoesNotEnd() {
    #expect(endsAt([loud, 0, 0, loud] + [Double](repeating: 0, count: 10)) == 4 + 3)  // a 0.5 s pause goes on
}

@Test func noSpeechGivesUpAfterSixSeconds() {
    #expect(endsAt([Double](repeating: 0, count: 100)) == 24)
}

@Test func endlessSpeechStopsAtFifteenSeconds() {
    #expect(endsAt([Double](repeating: loud, count: 100)) == 60)
}

@Test func gateTracksNoiseFloorWithMinimum() {
    #expect(abs(speechGate([Double](repeating: 0.03, count: 50) + [Double](repeating: loud, count: 12)) - 0.075) < 1e-9)  // wake speech ignored
    #expect(speechGate([Double](repeating: 0.001, count: 60)) == Listen.minGate)
    #expect(speechGate([]) == Listen.minGate)
}

@Test func percentileIsNumpys() {
    // np.percentile([1, 2, 4, 8, 16], 20) == 1.8, [16, 1, 8, 2, 4] at 99.5 == 15.84 and, rounded to
    // float32 like numpy does, np.percentile(np.float32([.1, .2, .7]), 99.5) == 0.6949999928474426
    #expect(percentile([1.0, 2, 4, 8, 16], 20) == 1.8)
    #expect(abs(percentile([16.0, 1, 8, 2, 4], 99.5) - 15.84) < 1e-12)
    #expect(percentile([Float(0.1), 0.2, 0.7], 99.5) == 0.6949999928474426 as Float)
}

func sine(_ peak: Float, _ count: Int = 16000) -> [Float] {
    (0..<count).map { Float(sin(Double($0) * 400 / Double(count - 1))) * peak }
}

@Test(arguments: [
    (Float(0.05), Float(Listen.levelPeak)),  // soft speech is brought up
    (Float(0.9), Float(Listen.levelPeak)),  // loud speech is brought down to the level the model was checked at
    (Float(0.0001), Float(0.0001 * Listen.levelMaxGain)),  // near-silence is not turned into loud noise
])
func leveledScalesToThePeakButCapsTheBoost(peak: Float, want: Float) {
    let top = leveled(sine(peak)).map(abs).max()!
    #expect(abs(top - want) <= 0.05 * want)
}

@Test func leveledLeavesSilenceAndOneClickAlone() {
    #expect(!leveled([Float](repeating: 0, count: 1600)).contains { $0 != 0 })
    var click = [Float](repeating: 0, count: 16000)
    click[100] = 1.0  // one sample is not the level of the utterance (99.5th percentile)
    #expect(leveled(click).map(abs).max()! <= Float(Listen.levelMaxGain))
}

// MARK: - Test doubles

final class Events {
    enum Heard: Equatable { case wake, text(String), note(String) }
    private let cond = NSCondition()
    private var items: [Heard] = []

    func put(_ h: Heard) { cond.withLock { items.append(h); cond.broadcast() } }
    var isEmpty: Bool { cond.withLock { items.isEmpty } }
    var all: [Heard] { cond.withLock { items } }

    func get(_ timeout: TimeInterval = 10) -> Heard? {
        let end = Date(timeIntervalSinceNow: timeout)
        return cond.withLock {
            while items.isEmpty { if !cond.wait(until: end) { return items.isEmpty ? nil : items.removeFirst() } }
            return items.removeFirst()
        }
    }

    /// The text of a note event.
    static func note(_ h: Heard?) -> String? { if case .note(let m)? = h { return m } else { return nil } }
}

/// A mic fed by the test through the real producer side of FrameQueue; reads wait 5 ms at most,
/// whatever the timeout.
class FakeMic: AudioSource {
    private let queue = FrameQueue()
    private let lock = NSLock()
    private var _closed = false, _unread = 0
    init(_ fs: [[Float]] = []) { feed(fs) }
    func feed(_ fs: [[Float]]) {
        for f in fs {
            lock.withLock { _unread += 1 }
            queue.append(samples: f)  // a whole frame
        }
    }
    /// Frames fed and not yet read.
    var unread: Int { lock.withLock { _unread } }
    var closed: Bool { lock.withLock { _closed } }
    func read(timeout: TimeInterval) throws -> [Float]? {
        let f = queue.get(timeout: 0.005)
        if f != nil { lock.withLock { _unread -= 1 } }
        return f
    }
    func close() { lock.withLock { _closed = true } }
}

/// A transcriber that says `texts` in turn, then `repeating`; `onCall` sees each audio first.
final class FakeStt {
    private let lock = NSLock()
    private var texts: [String]
    private let repeating: String, onCall: (([Float]) -> Void)?
    private var _heard: [[Float]] = []
    init(_ texts: String..., repeating: String = "", onCall: (([Float]) -> Void)? = nil) {
        self.texts = texts; self.repeating = repeating; self.onCall = onCall
    }
    var heard: [[Float]] { lock.withLock { _heard } }
    func callAsFunction(_ audio: [Float]) throws -> String {
        onCall?(audio)
        return lock.withLock { _heard.append(audio); return texts.isEmpty ? repeating : texts.removeFirst() }
    }
}

final class Clock {
    private let lock = NSLock()
    private var _t = 0.0
    var t: Double { get { lock.withLock { _t } } set { lock.withLock { _t = newValue } } }
    func advance(_ s: Double) { lock.withLock { _t += s } }
    func callAsFunction() -> Double { t }
}

/// A list the listener's threads append to.
final class Log<T> {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ x: T) { lock.withLock { items.append(x) } }
    var all: [T] { lock.withLock { items } }
}

func listener(_ events: Events, mic: @escaping () throws -> AudioSource, stt: @escaping () throws -> Transcribe,
              quick: (() throws -> Transcribe)? = nil, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime })
    -> Listener {
    Listener(onWake: { events.put(.wake) }, onText: { events.put(.text($0)) }, onNote: { events.put(.note($0)) },
             mic: mic, transcriber: stt, quick: quick, clock: clock)
}

/// A started listener on `mic` and `stt`; `noStall` for tests that jump a hand-driven clock while no
/// frames arrive (which looks like a dead mic).
func start(_ mic: FakeMic, _ stt: FakeStt, clock: Clock? = nil, quick: FakeStt? = nil, noStall: Bool = false)
    -> (Listener, Events) {
    let events = Events()
    let quick = quick ?? FakeStt()
    let lis = listener(events, mic: { mic }, stt: { stt.callAsFunction }, quick: { quick.callAsFunction },
                       clock: clock.map { c in { c.t } } ?? { ProcessInfo.processInfo.systemUptime })
    if noStall { lis.micStallS = 1e9 }
    #expect(lis.start())
    return (lis, events)
}

/// Quiet, n frames of speech, then a second of quiet.
func sentence(_ a: Int, _ n: Int = 5) -> [[Float]] {
    frames(a, a + 8) + frames(a + 8, a + 8 + n, speech) + frames(a + 8 + n, a + 30)
}

func drained(_ mic: FakeMic, timeout: TimeInterval = 3) {
    let end = Date(timeIntervalSinceNow: timeout)
    while mic.unread > 0 && Date() < end { Thread.sleep(forTimeInterval: 0.005) }
    Thread.sleep(forTimeInterval: 0.1)
}

func eventually(_ timeout: TimeInterval = 10, _ done: () -> Bool) -> Bool {
    let end = Date(timeIntervalSinceNow: timeout)
    while !done() && Date() < end { Thread.sleep(forTimeInterval: 0.005) }
    return done()
}

// MARK: - Listener

@Test func aSentenceWithTheNameIsARequest() {
    let mic = FakeMic(sentence(0))
    let stt = FakeStt("Robo, what time is it?")
    let (lis, events) = start(mic, stt)
    #expect([events.get(), events.get()] == [.wake, .text("what time is it?")])
    lis.stop()
    let heard = tags(stt.heard[0])
    #expect(heard[0] == 8 - Listen.preRollFrames && heard == Array(heard[0]...heard.last!))
}

@Test func otherSpeechIsIgnored() {
    let mic = FakeMic(sentence(0) + sentence(30))
    let stt = FakeStt("I'm studying linear algebra tonight.", "the robot vacuum is broken")
    let (lis, events) = start(mic, stt)
    drained(mic)
    lis.stop()
    #expect(events.isEmpty && stt.heard.count == 2)
}

@Test func aKnockIsNotTranscribed() {
    let mic = FakeMic(frames(0, 8) + frames(8, 10, speech) + frames(10, 30))
    let stt = FakeStt()
    let (lis, events) = start(mic, stt)
    drained(mic)
    lis.stop()
    #expect(stt.heard.isEmpty && events.isEmpty)
}

@Test func afterAnAnswerAReplyNeedsNoName() {
    let clock = Clock()
    let mic = FakeMic()
    let stt = FakeStt("and tomorrow?", "and next week?")
    let (lis, events) = start(mic, stt, clock: clock, noStall: true)
    lis.followUp(seconds: 10)
    mic.feed(sentence(0))
    #expect([events.get(), events.get()] == [.wake, .text("and tomorrow?")])
    clock.t = 30  // the window closed (and it was used once anyway)
    mic.feed(sentence(100))
    drained(mic)
    lis.stop()
    #expect(events.isEmpty)
}

@Test func clickTakesTheNextSentenceOrGivesUp() {
    let clock = Clock()
    let mic = FakeMic()
    let (lis, events) = start(mic, FakeStt("what's due"), clock: clock, noStall: true)
    lis.listenNow()
    mic.feed(sentence(0))
    #expect([events.get(), events.get()] == [.wake, .text("what's due")])
    lis.listenNow()
    clock.t = Listen.noSpeechS + 1
    #expect(events.get() == .text(""))
    lis.stop()
}

@Test func bareNameThenTheRequest() {
    let mic = FakeMic(sentence(0) + sentence(30))
    let (lis, events) = start(mic, FakeStt("Hey robo.", "open Moodle"))
    #expect([events.get(), events.get(), events.get()] == [.wake, .wake, .text("open Moodle")])
    lis.stop()
}

@Test func aMicThatGoesQuietStillEndsTheSentence() {
    let mic = FakeMic(frames(0, 8) + frames(8, 14, speech))  // then no frames at all
    let (lis, events) = start(mic, FakeStt("Robo, open Moodle"))
    #expect([events.get(), events.get()] == [.wake, .text("open Moodle")])
    lis.stop()
}

@Test func anErrorIsReportedNotSilent() {
    final class Broken: FakeMic {
        override func read(timeout: TimeInterval) throws -> [Float]? { throw VoiceError("device unplugged") }
    }
    let (lis, events) = start(Broken(), FakeStt())
    #expect(Events.note(events.get())?.contains("unplugged") == true)
    #expect(eventually { !lis.running })
}

@Test func stopReturnsQuicklyWhileTranscribing() {
    let mic = FakeMic(sentence(0))
    let events = Events()
    let lis = listener(events, mic: { mic }, stt: { { _ in Thread.sleep(forTimeInterval: 3); return "x" } })
    #expect(lis.start())
    drained(mic)
    let t = Date()
    lis.stop(wait: 0.2)
    #expect(Date().timeIntervalSince(t) < 1.0)
}

@Test func aMicThatWillNotOpenIsReportedLaterNotByStart() {
    let events = Events()
    let lis = listener(events, mic: { throw VoiceError("no input device") }, stt: { { _ in "" } })
    #expect(lis.start())  // the mic opens on the listener thread, so start() cannot know yet
    #expect(events.get() == .note("I can't open the microphone: no input device"))
    #expect(eventually { !lis.running } && !lis.ready)
    Thread.sleep(forTimeInterval: 0.05)
    #expect(events.isEmpty)
}

/// A mic whose opening blocks until the test signals, like AVAudioEngine behind macOS's permission dialog.
final class Gate {
    let open = DispatchSemaphore(value: 0)
    /// The value once signalled; a hung test gives up after 10 s instead of waiting for ever.
    let waiting = Log<Int>()
    func through<T>(_ value: T) -> () throws -> T { { self.waiting.append(1); _ = self.open.wait(timeout: .now() + 10); return value } }
}

@Test func startNeverWaitsForTheMicrophoneToOpen() {
    let gate = Gate(), events = Events(), mic = FakeMic(sentence(0))
    let lis = listener(events, mic: gate.through(mic as AudioSource), stt: { FakeStt("Robo, what time is it?").callAsFunction },
                       quick: { FakeStt().callAsFunction })
    let t = Date()
    #expect(lis.start())
    lis.listenNow(); lis.followUp(seconds: 1)  // what the UI does meanwhile
    #expect(!lis.running && !lis.ready)
    #expect(Date().timeIntervalSince(t) < 5 && events.isEmpty)  // a start() that waited would take the gate's 10 s
    gate.open.signal()  // the user clicked Allow
    #expect([events.get(), events.get()] == [.wake, .text("what time is it?")])
    #expect(eventually { lis.ready })
    lis.stop()
    #expect(!lis.running && mic.closed)
}

@Test func stopWhileTheMicrophoneIsOpeningReturnsAtOnceAndClosesItWhenItOpens() {
    let gate = Gate(), events = Events(), mic = FakeMic(sentence(0)), loads = Log<Int>()
    let lis = listener(events, mic: gate.through(mic as AudioSource), stt: { loads.append(1); return FakeStt("Robo, hi").callAsFunction })
    #expect(lis.start())
    let t = Date()
    #expect(eventually { gate.waiting.all.count == 1 })  // the thread is inside the blocked open
    lis.stop()  // its default wait is 5.5 s: it must not use it
    #expect(Date().timeIntervalSince(t) < 3 && !lis.running)
    gate.open.signal()
    #expect(eventually { mic.closed })
    Thread.sleep(forTimeInterval: 0.05)
    #expect(events.isEmpty && loads.all.isEmpty && !lis.running)  // it never started listening
}

@Test func aMicThatOpensAfterAStopAndRestartIsNotUsed() {
    let gate = Gate(), events = Events(), stale = FakeMic(sentence(0)), fresh = FakeMic()
    let opened = Log<Int>()
    let lis = listener(events, mic: {
        opened.append(1)
        if opened.all.count == 1 { _ = gate.open.wait(timeout: .now() + 10); return stale }
        return fresh
    }, stt: { FakeStt("Robo, hi").callAsFunction })
    #expect(lis.start())
    #expect(eventually { opened.all.count == 1 })  // the first thread is the one inside the blocked open (which thread
    lis.stop()                                      // reaches the factory first is up to the scheduler, so wait for it)
    #expect(lis.start() && eventually { lis.ready })  // the second start is the one that counts
    gate.open.signal()
    #expect(eventually { stale.closed })
    Thread.sleep(forTimeInterval: 0.05)
    #expect(events.isEmpty && lis.ready && !fresh.closed)
    lis.stop()
    #expect(fresh.closed && !lis.running)
}

@Test func aSpeechModelThatWillNotLoadIsReportedLaterAndFreesTheMic() {
    let events = Events(), mic = FakeMic()
    let lis = listener(events, mic: { mic }, stt: { throw VoiceError("model missing") })
    #expect(lis.start())  // the model loads on the listener thread, so start() cannot know yet
    #expect(events.get() == .note("I can't load speech recognition: model missing"))
    #expect(mic.closed)
    #expect(eventually { !lis.running })
}

@Test func startReturnsBeforeTheModelHasLoadedAndTheAudioIsKept() {
    let release = Flag(), events = Events()
    let stt = FakeStt("Robo, what time is it?"), mic = FakeMic(sentence(0))  // spoken while loading
    let lis = listener(events, mic: { mic }, stt: { release.wait(5); return stt.callAsFunction },
                       quick: { FakeStt().callAsFunction })
    #expect(!lis.running)
    let t = Date()
    #expect(lis.start() && eventually { lis.running })
    #expect(Date().timeIntervalSince(t) < 1.0 && events.isEmpty && mic.unread > 0)
    #expect(!lis.ready)  // alive, but the model has not loaded
    release.set()
    #expect([events.get(), events.get()] == [.wake, .text("what time is it?")])
    #expect(lis.ready)
    lis.stop()
    #expect(!lis.running && !lis.ready)
}

@Test func roboPerksUpWhileYouAreStillTalking() {
    let order = Log<(String, Int)>()
    let long = frames(0, 8) + frames(8, 48, speech) + frames(48, 70)  // 3.2 s of speech
    let final = FakeStt(repeating: "Robo, what is the time in Tokyo right now?",
                        onCall: { order.append(("final", $0.count / Listen.frame)) })
    let quick = FakeStt(repeating: "Robo, what is", onCall: { order.append(("quick", $0.count / Listen.frame)) })
    let (lis, events) = start(FakeMic(long), final, quick: quick)
    #expect(events.get() == .wake)
    #expect(order.all[0].0 == "quick" && order.all[0].1 < 30)  // early, mid-sentence
    #expect(events.get() == .text("what is the time in Tokyo right now?"))
    lis.stop()
    let last = order.all.last!
    #expect(last.0 == "final" && order.all.filter { $0.0 == "final" && $0.1 == last.1 }.count == 1)
    #expect(events.isEmpty)  // one wake per sentence
}

@Test func anExpectedSentenceWakesRoboAtOnce() {
    let order = Log<String>(), done = Events(), mic = FakeMic()
    let lis = Listener(onWake: { order.append("wake") }, onText: { done.put(.text($0)) }, onNote: { _ in },
                       mic: { mic }, transcriber: { { _ in order.append("final"); return "and tomorrow?" } },
                       quick: { FakeStt().callAsFunction })
    #expect(lis.start())
    lis.followUp(seconds: 10)
    mic.feed(sentence(0))
    #expect(done.get() == .text("and tomorrow?"))
    lis.stop()
    #expect(order.all == ["wake", "final"])  // robo showed it was listening before transcribing
}

@Test func otherSpeechGetsOnlyTheQuickCheck() {
    let calls = Log<String>()
    let long = frames(0, 8) + frames(8, 48, speech) + frames(48, 70)
    let mic = FakeMic(long)
    let (lis, events) = start(mic, FakeStt("I'm going to show you how to do this."),
                              quick: FakeStt(repeating: "I'm going to show you", onCall: { _ in calls.append("quick") }))
    drained(mic)
    Thread.sleep(forTimeInterval: 0.2)
    lis.stop()
    #expect(events.isEmpty && calls.all == ["quick"])
}

@Test func theWordOverDoesNotEndARequest() {
    // 16 s of sound, then quiet: only the quiet ends it, and "over" stays in the text
    let clip = frames(0, 8) + frames(8, 208, speech) + frames(208, 260)
    let stt = FakeStt("Robo, what's the date, over.")
    let (lis, events) = start(FakeMic(clip), stt, quick: FakeStt("Robo, what's the date"))
    #expect(events.get() == .wake)
    #expect(events.get() == .text("what's the date, over."))
    lis.stop()
    #expect(stt.heard.count == 1 && stt.heard[0].count / Listen.frame > 200)
}

@Test func oneModelServesTheQuickChecksByDefault() {
    let loads = Log<Int>()
    let events = Events()
    let lis = Listener(onWake: {}, onText: { _ in }, onNote: { events.put(.note($0)) }, mic: { FakeMic() },
                       transcriber: { loads.append(1); return { _ in "" } })  // Parakeet is fast enough for both
    #expect(lis.start() && eventually { lis.ready })
    lis.stop()
    #expect(loads.all.count == 1)
}

@Test func onceRoboIsListeningAThinkingPauseDoesNotEndTheRequest() {
    // woke by name, then 2.4 s of silence mid-request, then more words; 3.2 s of silence ends it
    let clip = frames(0, 8) + frames(8, 20, speech) + frames(20, 50) + frames(50, 60, speech) + frames(60, 100)
    let stt = FakeStt("Robo, plan my day and also check my mail")
    let (lis, events) = start(FakeMic(clip), stt, quick: FakeStt("Robo, plan my"))
    #expect(events.get() == .wake)
    #expect(events.get() == .text("plan my day and also check my mail"))
    lis.stop()
    #expect(stt.heard.count == 1 && tags(stt.heard[0]).contains(59))  // one request, both halves
}

@Test func aLongRequestIsNotCutAtFifteenSeconds() {
    let clip = frames(0, 8) + frames(8, 8 + 375, speech) + frames(383, 420)  // 30 s of speech
    let stt = FakeStt("Robo, a long question")
    let (lis, events) = start(FakeMic(clip), stt, quick: FakeStt("Robo, a"))
    #expect(events.get() == .wake)
    #expect(events.get(10) == .text("a long question"))
    lis.stop()
    #expect(stt.heard[0].count / Listen.frame > 375)
}

// MARK: - A microphone that dies or only gives silence

/// A mic on a hand-driven clock: every empty read is a read timeout that passes.
final class Ticking: FakeMic {
    let clock: Clock
    init(_ clock: Clock, _ fs: [[Float]] = []) { self.clock = clock; super.init(fs) }
    override func read(timeout: TimeInterval) throws -> [Float]? {
        let f = try super.read(timeout: timeout)
        if f == nil { clock.advance(timeout) }
        return f
    }
}

@Test func aMicThatStopsDeliveringIsReopenedAndTheNextOutageReportedAgain() {
    let clock = Clock(), events = Events()
    let dead = Ticking(clock), fresh = Ticking(clock, sentence(0))
    let opened = Log<Int>()
    let lis = listener(events, mic: {  // the first opening gives the mic that dies, reopening fails once, then a fresh one
        opened.append(1)
        switch opened.all.count {
        case 1: return dead
        case 3: return fresh
        default: throw VoiceError("no device")
        }
    }, stt: { { _ in "Robo, what time is it?" } }, quick: { FakeStt().callAsFunction }, clock: { clock.t })
    lis.micRetryS = 0.01
    #expect(lis.start())
    #expect(events.get() == .note("I lost the microphone, reconnecting..."))
    #expect([events.get(), events.get()] == [.wake, .text("what time is it?")])
    #expect(Events.note(events.get()) != nil)  // the fresh mic died too: reported again
    lis.stop()  // ...and stop() ends the retrying
    #expect(dead.closed && fresh.closed && events.isEmpty && !lis.running)
}

/// Plays `script`: a frame, or nil for a read timeout that passes on the hand-driven clock; once it
/// runs out, the mic just waits.
final class Scripted: FakeMic {
    let clock: Clock
    private let scriptLock = NSLock()
    private var _script: [[Float]?]
    init(_ clock: Clock, _ script: [[Float]?]) { self.clock = clock; _script = script; super.init() }
    var remaining: Int { scriptLock.withLock { _script.count } }
    override func read(timeout: TimeInterval) throws -> [Float]? {
        let item: [Float]?? = scriptLock.withLock { _script.isEmpty ? nil : .some(_script.removeFirst()) }
        guard let item else {  // out of script
            Thread.sleep(forTimeInterval: 0.005)
            return nil
        }
        if item == nil { clock.advance(timeout) }
        return item
    }
}

@Test(arguments: [(9, false), (10, true)])  // 4.5 s, 5 s
func onlyAGapOfMicStallSecondsIsAnOutage(timeouts: Int, reported: Bool) {
    let clock = Clock(), events = Events()
    let script: [[Float]?] = frames(0, 4) + [[Float]?](repeating: nil, count: timeouts) + frames(4, 6)
    let mic = Scripted(clock, script)
    let lis = listener(events, mic: { mic }, stt: { { _ in "" } }, clock: { clock.t })
    #expect(lis.start())
    _ = eventually(5) { mic.remaining == 0 }
    Thread.sleep(forTimeInterval: 0.05)
    lis.stop()
    #expect(!events.isEmpty == reported)
}

@Test func aMicThatOnlyGivesSilenceIsReportedOnceUntilSoundReturns() {
    func zeros(_ n: Int) -> [[Float]] { (0..<n).map { _ in [Float](repeating: 0, count: Listen.frame) } }
    let n = Listen.silentFrames
    let mic = FakeMic(zeros(n + 20) + frames(1, 4) + zeros(n + 5) + frames(5, 8) + zeros(n - 1) + frames(8, 10))
    let (lis, events) = start(mic, FakeStt())
    drained(mic)
    #expect(lis.running)  // not fatal
    lis.stop()
    let notes = events.all.compactMap { Events.note($0) }
    #expect(notes.count == 2 && events.all.count == 2)
    #expect(notes.allSatisfy { $0.contains("only gives me silence") && $0.contains("Microphone") })
}
