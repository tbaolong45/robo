// Hands-free voice input: robo hears every sentence (Parakeet TDT v2, on this laptop) and takes the
// ones that call it by name ("robo, what time is it?", "what's due, robo?"), plus anything said in the
// few seconds after it answers, or after a click on its face. Nothing leaves the laptop.
// Port of src/robo/listen.py.
import Accelerate
import Foundation
import os

private let log = Logger(subsystem: "ai.robo", category: "listen")

public enum Listen {
    public static let sampleRate = 16000
    public static let frame = 1280  // 80 ms
    public static let frameS = Double(frame) / Double(sampleRate)
    static let preRollFrames = 6  // ~0.5 s kept from before the voice crossed the gate (soft first syllables)
    static let noiseFrames = 62  // ~5 s of quiet RMS for the noise floor
    static let noisePercentile = 20.0
    static let gateFactor = 2.5  // speech = RMS above 2.5x the room's noise floor...
    public static let minGate = 0.02  // ...and above this (float RMS, -1..1)
    static let endSilenceS = 0.7  // other speech (TV, people): short, so little is transcribed
    public static let noSpeechS = 6.0
    static let maxUtteranceS = 15.0
    static let patientSilenceS = 3.0  // talking to robo: a pause to think does not end the request (no end word)
    static let patientMaxS = 120.0
    public static let minSpeechFrames = 4  // ~0.3 s above the gate, or it was a knock, not a sentence
    public static let readTimeout = 0.5
    static let earlyFrames = 15  // ~1.2 s into a sentence, check whether it starts with robo's name
    static let micStallS = 5.0  // no frame for this long: the mic is gone (unplugged, or stuck after a sleep)
    static let micRetryS = 5.0  // ...then it is reopened this often
    static let silentFrames = 38  // ~3 s of exact zeros: that is what a microphone without permission delivers
    static let levelPeak = 0.5  // Parakeet reads soft speech worse (TTS at 0.15x: 44 -> 48 of 50 names caught)
    static let levelMaxGain = 20.0  // ...but near-silence must not become loud noise
}

/// A failure with a message for the user (what Python raises as OSError or RuntimeError).
public struct VoiceError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

func describe(_ error: Error) -> String { (error as? VoiceError)?.description ?? error.localizedDescription }

// MARK: - Name matcher

// How Parakeet writes the user's "robo" (measured on two recordings of their voice): Robo, Rubo,
// Robbo, Roombo; at the start of a sentence also Robot and Rubble. "Robot"/"rubble" at the end, and
// "robots", are just words ("bought a robot.", "Robots are interesting").
private let sound = #"r(?:o|u|oo|ou)m?bb?"#
private let startName = "\(sound)(?:o|oh|ow|ot|le)"
private let endName = "\(sound)(?:o|oh|ow)"

// NSRegularExpression, not Swift's Regex: its \b is the simple \w boundary Python uses.
private func regex(_ pattern: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
}

// \W* after the greeting: Parakeet sometimes glues it to the name ("Yorobo"); the name must still
// fit whole, so "Hirobumi" and "Hiring" do not match
private let lead = regex(#"^\W*(?:(?:hey|hi|high|hay|ok|okay|yo)\W*)?"# + startName + #"\b\W*"#)
private let tail = regex(#"\W*\b"# + endName + #"\W*$"#)
private let anywhere = regex(#"\b"# + endName + #"\b"#)  // "robo"-like words are rare anywhere

private func whole(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }
private func found(_ re: NSRegularExpression, in s: String) -> Bool { re.firstMatch(in: s, range: whole(s)) != nil }

/// Python's `\w` for a str: a letter, a number or an underscore.
func isWord(_ c: Unicode.Scalar) -> Bool {
    switch c.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
         .decimalNumber, .letterNumber, .otherNumber: true
    default: c == "_"
    }
}

func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

/// The request in `text` if it calls robo by name, else nil ("" = just the name).
public func addressed(_ text: String) -> String? {
    guard found(lead, in: text) || found(tail, in: text) || found(anywhere, in: text) else { return nil }
    return withoutName(text)
}

/// `text` without a leading or trailing "(hey) robo".
public func withoutName(_ text: String) -> String {
    var s = text
    if let m = lead.firstMatch(in: s, range: whole(s)) { s = (s as NSString).replacingCharacters(in: m.range, with: "") }
    s = tail.stringByReplacingMatches(in: s, range: whole(s), withTemplate: "")
    let command = trimmed(s)
    return command.unicodeScalars.contains(where: isWord) ? command : ""
}

// MARK: - Audio levels

func rms(_ frame: [Float]) -> Double {
    var r: Float = 0
    vDSP_rmsqv(frame, 1, &r, vDSP_Length(frame.count))
    return Double(r)
}

/// numpy.percentile (linear interpolation) of `values`, `q` in 0...100, rounded to the element
/// type like numpy does: for float32 audio the peak is a float32, and the gain made from it must be
/// the same to the last bit (the nearly empty top mel bands only hold rounding noise of the signal).
func percentile<T: BinaryFloatingPoint>(_ values: [T], _ q: Double) -> T {
    if values.isEmpty { return 0 }  // numpy raises; nothing is a silence here
    let s = values.sorted()
    let v = Double(s.count - 1) * (q / 100)
    let lo = Int(v.rounded(.down)), hi = min(lo + 1, s.count - 1)
    let a = Double(s[lo]), b = Double(s[hi])
    let t = v - Double(lo), diff = Double(s[hi] - s[lo])
    return T(t >= 0.5 ? b - diff * (1 - t) : a + diff * t)
}

/// `audio` scaled so its peak (99.5th percentile, so one click doesn't count) is `levelPeak`.
func leveled(_ audio: [Float]) -> [Float] {
    let peak = Double(percentile(audio.map { abs($0) }, 99.5))
    if peak == 0 { return audio }
    var gain = Float(min(Listen.levelMaxGain, Listen.levelPeak / peak))
    var out = [Float](repeating: 0, count: audio.count)
    vDSP_vsmul(audio, 1, &gain, &out, 1, vDSP_Length(audio.count))
    return out
}

/// RMS above which a frame counts as speech, from recent quiet RMS (the room's noise).
func speechGate(_ idleRms: [Double]) -> Double {
    max(Listen.gateFactor * percentile(idleRms, Listen.noisePercentile), Listen.minGate)
}

/// The last `max` items appended (Python's `deque(maxlen=)`).
struct Ring<T> {
    private(set) var items: [T] = []
    let max: Int
    init(_ max: Int) { self.max = max }
    mutating func append(_ x: T) {
        items.append(x)
        if items.count > max { items.removeFirst() }
    }
    mutating func removeAll() { items.removeAll() }
}

/// Decides, frame by frame, when one spoken utterance is over.
struct Endpointer {
    let gate: Double, frameS: Double
    var endSilence = Listen.endSilenceS, maxS = Listen.maxUtteranceS
    private var frames = 0, silent = 0, heard = false

    init(gate: Double, frameS: Double = Listen.frameS) { self.gate = gate; self.frameS = frameS }

    /// Add one frame's RMS; true once the utterance ended (or never started).
    mutating func feed(_ level: Double) -> Bool {
        frames += 1
        if level > gate { heard = true; silent = 0 } else { silent += 1 }
        if Double(frames) * frameS >= maxS { return true }
        if heard { return Double(silent) * frameS >= endSilence }
        return Double(frames) * frameS >= Listen.noSpeechS
    }
}

// MARK: - Threads

/// A flag threads can wait on (Python's threading.Event).
final class Flag {
    private let cond = NSCondition()
    private var flag: Bool
    init(set: Bool = false) { flag = set }
    var isSet: Bool { cond.withLock { flag } }
    func set() { cond.withLock { flag = true; cond.broadcast() } }
    func clear() { cond.withLock { flag = false } }
    /// True if the flag was set within `timeout` seconds.
    @discardableResult func wait(_ timeout: TimeInterval) -> Bool {
        let end = Date(timeIntervalSinceNow: timeout)
        return cond.withLock {
            while !flag { if !cond.wait(until: end) { return flag } }
            return true
        }
    }
}

// MARK: - Listener

public typealias Transcribe = ([Float]) throws -> String

/// Hears every sentence on its own thread; callbacks run on that thread or the inference queue.
///
/// `onWake()` when robo is called by name, then `onText(request)`. A request ends after
/// `patientSilenceS` of quiet. A sentence also counts without the name while robo expects one:
/// after `listenNow()` (a click; `onText("")` if nothing is said within `noSpeechS`), after
/// `followUp(seconds:)` (it just answered), or right after a bare "robo". A mic that stops
/// delivering is reopened; one that only gives silence is reported through `onNote`, like every
/// other message for the user.
///
/// Unlike the Python listener, transcription runs on its own serial queue, so the loop keeps
/// reading frames (noise floor, pre-roll, mic watch) while the last sentence is transcribed. The
/// results are the same: before the next sentence starts or a click window times out, the loop
/// waits for the transcription in flight, as Python's inline call did.
public final class Listener {
    let onWake: () -> Void, onText: (String) -> Void, onNote: (String) -> Void
    private let makeMic: () throws -> AudioSource
    private let makeStt: () throws -> Transcribe
    private let makeQuick: (() throws -> Transcribe)?
    private let clock: () -> Double
    var micStallS = Listen.micStallS, micRetryS = Listen.micRetryS  // tests shorten them

    private let lock = NSLock()
    private var loaded = false  // the speech model is loaded
    private var alive = false  // the mic is open and the thread runs
    private var opening = false  // the thread is still opening the mic
    private var generation = 0  // which start() the thread belongs to
    private var openUntil = 0.0  // a sentence without the name counts until then
    private var asked = false  // the open window came from a click or a bare "robo": end it with ""
    private var failure: Error?  // a transcription that threw: the loop stops with it
    private let stopping = Flag(), finished = Flag(set: true)
    private let infer = DispatchQueue(label: "robo.infer")
    private let inflight = DispatchGroup()
    private var lastAudio = 0.0  // when the mic last delivered a frame
    private var zeros = 0  // consecutive all-zero frames

    public init(onWake: @escaping () -> Void, onText: @escaping (String) -> Void,
                onNote: @escaping (String) -> Void,
                mic: @escaping () throws -> AudioSource = { try Microphone() },
                transcriber: @escaping () throws -> Transcribe = { try Parakeet().callAsFunction },
                quick: (() throws -> Transcribe)? = nil,
                clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.onWake = onWake; self.onText = onText; self.onNote = onNote
        makeMic = mic; makeStt = transcriber; makeQuick = quick; self.clock = clock
    }

    /// The mic is open and the listener thread is alive.
    public var running: Bool { lock.withLock { alive } }

    /// Running and the speech model is loaded: what you say is understood from now on.
    public var ready: Bool { lock.withLock { alive && loaded } }

    /// Start listening and return at once (always true; Python returned false for a mic that would
    /// not open). The listener thread opens the mic, which can block for as long as the user takes to
    /// answer macOS's permission dialog, then loads speech recognition while the audio spoken
    /// meanwhile is kept. A mic or model that fails is reported through `onNote`; `running` and
    /// `ready` say how far it got. Nothing here waits for the mic, so the UI thread keeps pumping.
    public func start() -> Bool {
        let mine = lock.withLock { () -> Int in
            generation += 1
            alive = false; opening = true; loaded = false; failure = nil
            return generation
        }
        stopping.clear(); finished.clear()
        let thread = Thread { [self] in openAndRun(mine) }
        thread.name = "robo-listen"
        thread.qualityOfService = .userInitiated
        thread.start()
        return true
    }

    /// The listener thread: open the mic, run, and say so when done. A start() or stop() that came
    /// while the mic was opening makes this one stale: it closes the mic and leaves everything else alone.
    private func openAndRun(_ mine: Int) {
        func wanted() -> Bool { lock.withLock { generation == mine } && !stopping.isSet }
        var mic: AudioSource?
        if wanted() {  // a stop() or start() before this thread ran: the mic is not even opened
            do { mic = try makeMic() } catch {
                if wanted() { onNote("I can't open the microphone: \(describe(error))") }
            }
        }
        // decided under the lock stop() reads `opening` with: a stop() that sets `stopping` first is seen
        // here, one that comes later finds `opening` false and waits for this thread
        let go = lock.withLock { () -> Bool in
            guard mic != nil, generation == mine, !stopping.isSet else { return false }
            alive = true; opening = false
            return true
        }
        if let mic, go {
            loadAndRun(mic)
        } else {
            mic?.close()
        }
        let current = lock.withLock { () -> Bool in
            if generation == mine { alive = false; opening = false }
            return generation == mine
        }
        if current { finished.set() }
    }

    private func loadAndRun(_ mic: AudioSource) {
        let transcribe: Transcribe, quick: Transcribe
        do {
            transcribe = try makeStt()
            quick = try makeQuick?() ?? transcribe
        } catch {
            log.error("speech recognition failed to load: \(describe(error))")
            mic.close()
            onNote("I can't load speech recognition: \(describe(error))")
            return
        }
        lock.withLock { loaded = true }
        lastAudio = clock()
        run(mic, transcribe, quick)
    }

    /// The next sentence is for robo (the face was clicked).
    public func listenNow() { open(Listen.noSpeechS, asked: true) }

    /// Robo just answered: a reply in the next `seconds` needs no name.
    public func followUp(seconds: Double) { open(seconds, asked: false) }

    private func open(_ seconds: Double, asked: Bool) {
        let until = clock() + seconds
        lock.withLock { openUntil = until; self.asked = asked }
    }

    /// End the thread; waits up to `wait` s (a transcription in flight finishes on its own). A mic
    /// still opening is not waited for: it is closed as soon as it opens.
    public func stop(wait: Double = Listen.readTimeout + 5) {
        stopping.set()
        if !lock.withLock({ opening }) { finished.wait(wait) }
    }

    private func run(_ first: AudioSource, _ transcribe: @escaping Transcribe, _ quick: Transcribe) {
        var mic: AudioSource? = first
        var preRoll = Ring<[Float]>(Listen.preRollFrames)
        var quiet = Ring<Double>(Listen.noiseFrames)
        defer { mic?.close() }
        do {
            while !stopping.isSet && lock.withLock({ failure == nil }) {
                if inflight.wait(timeout: .now()) == .success {  // else the transcription may still end the window
                    let gaveUp = lock.withLock { () -> Bool in
                        let expired = asked && clock() >= openUntil
                        if expired { asked = false }  // clicked (or said "robo"), then nothing: give up
                        return expired
                    }
                    if gaveUp { onText("") }
                }
                guard let frame = try read(mic!) else {
                    if clock() - lastAudio >= micStallS {
                        mic = reopen(mic!)
                        if mic == nil { return }  // stop() came first
                    }
                    continue
                }
                let gate = speechGate(quiet.items), level = rms(frame)
                if level <= gate {
                    preRoll.append(frame)
                    quiet.append(level)
                    continue
                }
                inflight.wait()  // the last sentence's verdict decides whether robo expects this one
                let woke = lock.withLock { clock() < openUntil }  // robo expects this sentence: show it now
                if woke { onWake() }
                let u = try record(mic!, preRoll.items + [frame], gate: gate, woke: woke, quick: quick)
                preRoll.removeAll()
                if u.loud >= Listen.minSpeechFrames {
                    let audio = u.frames.flatMap { $0 }
                    infer.async(group: inflight) { [self] in
                        do {
                            let text = try transcribe(audio)
                            heard(text, woke: u.woke)
                        } catch { lock.withLock { failure = error } }
                    }
                }
            }
            inflight.wait()
            if let e = lock.withLock({ failure }) { throw e }
        } catch {  // the mic or the recogniser failed: say so, stop listening
            log.error("listener stopped: \(describe(error))")
            onNote("Voice input stopped: \(describe(error))")
        }
    }

    /// One frame (nil on timeout), noting when audio last came and if it is only silence.
    private func read(_ mic: AudioSource) throws -> [Float]? {
        guard let frame = try mic.read(timeout: Listen.readTimeout) else { return nil }
        lastAudio = clock()
        zeros = frame.contains { $0 != 0 } ? 0 : zeros + 1
        if zeros == Listen.silentFrames {  // once per run of zeros
            onNote("The microphone only gives me silence. Check that it isn't muted and that robo may use "
                   + "it (on a Mac: System Settings -> Privacy & Security -> Microphone).")
        }
        return frame
    }

    /// The mic delivered nothing for `micStallS`: say so, close it, reopen it every `micRetryS`.
    /// nil if stop() came first.
    private func reopen(_ dead: AudioSource) -> AudioSource? {
        onNote("I lost the microphone, reconnecting...")
        dead.close()
        while true {
            do {
                let mic = try makeMic()
                lastAudio = clock()
                return mic
            } catch { log.warning("microphone still unavailable: \(describe(error))") }
            if stopping.wait(micRetryS) { return nil }
        }
    }

    /// Decide whether a transcribed sentence was for robo (`woke`: robo already showed it).
    private func heard(_ text: String, woke: Bool) {
        if stopping.isSet { return }
        guard let request = woke ? withoutName(text) : addressed(text) else { return }  // TV, other people
        if !woke { onWake() }
        lock.withLock { openUntil = 0; asked = false }
        if request.isEmpty {  // just "robo" (or nothing intelligible): the request follows
            open(Listen.noSpeechS, asked: true)
        } else {
            onText(request)
        }
    }

    struct Utterance { var frames: [[Float]]; var loud: Int; var woke: Bool }

    /// Frames until the sentence ends (or stop()), how many were above the gate, and whether robo
    /// woke up (a quick early check found its name at the start).
    private func record(_ mic: AudioSource, _ first: [[Float]], gate: Double, woke: Bool,
                        quick: Transcribe) throws -> Utterance {
        var u = Utterance(frames: first, loud: 1, woke: woke)
        var ep = Endpointer(gate: gate)
        let start = first.count
        _ = ep.feed(rms(first.last!))  // the frame that crossed the gate
        if woke { ep.endSilence = Listen.patientSilenceS; ep.maxS = Listen.patientMaxS }
        let timeoutFrames = Int((Listen.readTimeout / Listen.frameS).rounded(.toNearestOrEven))
        while !stopping.isSet {
            guard let frame = try read(mic) else {  // the mic went quiet: that time counts as silence
                if (0..<timeoutFrames).contains(where: { _ in ep.feed(0) }) { break }
                continue
            }
            u.frames.append(frame)
            let level = rms(frame)
            if level > gate { u.loud += 1 }
            if ep.feed(level) { break }
            if !u.woke && u.frames.count - start == Listen.earlyFrames {
                u.woke = addressed(try infer.sync { try quick(u.frames.flatMap { $0 }) }) != nil
                if u.woke {
                    onWake()
                    ep.endSilence = Listen.patientSilenceS; ep.maxS = Listen.patientMaxS
                }
            }
        }
        return u
    }
}
