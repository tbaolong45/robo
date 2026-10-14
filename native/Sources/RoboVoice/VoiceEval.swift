// Does robo take the sentences that call it and ignore the rest? Real speech model, real matcher.
// Port of scripts/voice_eval.py.
//
//   robo voice-eval OUT_DIR       macOS `say` voices (model must be cached)
//   robo voice-eval --record DIR  YOU read 10 prompted phrases, saved as DIR/*.wav
//                                 (Enter starts each; --wait SECONDS starts it after that long instead,
//                                 for a run with no terminal)
//   robo voice-eval --wavs DIR    score DIR/robo_*.wav and DIR/other_*.wav
//
// Prints a line per phrase, then the misses (a sentence for robo that was not taken) and the false
// positives (other speech that was taken). For your own clips it also says whether each one clears
// the speech gate (`Listen.minGate`): a clip that does not would never reach the model. Synthetic
// voices are not yours: use their score to compare a change with the one before it, not to tune to
// a number.
import Foundation

private let voices = ["Samantha", "Daniel", "Karen", "Moira", "Alex", "Tessa", "Aman", "Fred", "Rishi", "Reed"]
private let forRobo = [
    "Robo, what time is it?",
    "Hey robo, what's due this week?",
    "What's due this week, robo?",
    "Robo.",
    "Hey Robo",
    "Okay robo, plan my day.",
    "Can you help me with my homework, robo?",
    "Robo, I got eight out of ten on the quiz.",
    "Yo robo, open my calendar.",
    "Robo draw me a diagram of the water cycle.",
]
private let notForRobo = [
    "I bought a robot yesterday.",
    "Robots are interesting.",
    "The weather is nice today.",
    "Let's watch the game tonight.",
    // a known false positive on purpose: Parakeet often writes the user's "Robo" as "Rubble"
    "Rubble was everywhere after the storm.",
    "Turn the volume up a little bit.",
    "Welcome back to the show everybody.",
    "The robbery happened on Tuesday.",
    "Throw the ball over the fence.",
    "Rob, can you pass me the salt?",
]

struct EvalError: Error { let message: String }

/// Python's repr() of a str, for lines that can be compared with voice_eval.py's.
func pyRepr(_ s: String?) -> String {
    guard let s else { return "None" }
    let quote: Character = s.contains("'") && !s.contains("\"") ? "\"" : "'"
    var out = String(quote)
    for c in s {
        switch c {
        case quote, "\\": out += "\\\(c)"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default: out.append(c)
        }
    }
    return out + String(quote)
}

private func pad(_ s: String, _ width: Int) -> String { s + String(repeating: " ", count: max(0, width - s.count)) }

/// 16-bit mono 16 kHz PCM of a RIFF wav file, as floats (-1...1).
func readWav(_ url: URL) throws -> [Float] {
    let d = try Data(contentsOf: url)
    func u16(_ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 }
    func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
    var i = 12, format: (rate: Int, channels: Int, bits: Int)?
    while i + 8 <= d.count {
        let id = String(decoding: d[i..<i + 4], as: UTF8.self), size = u32(i + 4)
        if id == "fmt " {
            guard i + 24 <= d.count else { throw EvalError(message: "\(url.lastPathComponent): truncated fmt chunk") }
            format = (u32(i + 12), u16(i + 10), u16(i + 22))
        }
        if id == "data" {
            guard format?.rate == Listen.sampleRate, format?.channels == 1, format?.bits == 16 else {
                throw EvalError(message: "\(url.lastPathComponent): need 16 kHz mono 16-bit (use --record)")
            }
            let end = min(i + 8 + size, d.count)
            return stride(from: i + 8, to: end - 1, by: 2).map { Float(Int16(truncatingIfNeeded: u16($0))) / 32768 }
        }
        i += 8 + size + size % 2
    }
    throw EvalError(message: "\(url.lastPathComponent): no audio")
}

/// 16 kHz mono audio of `voice` saying `text` with a little silence around it.
private func speak(_ voice: String, _ text: String, _ path: URL) throws -> [Float]? {
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", voice, "-o", path.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
    say.standardOutput = FileHandle.nullDevice
    say.standardError = FileHandle.nullDevice
    try say.run()
    say.waitUntilExit()
    if say.terminationStatus != 0 { return nil }
    let silence = [Float](repeating: 0, count: 8000)
    return try silence + readWav(path) + silence
}

private func loadModel() throws -> Parakeet {
    let start = Date()
    let stt = try Parakeet()
    print(String(format: "model loaded in %.1fs", Date().timeIntervalSince(start)))
    return stt
}

private func synthetic(_ out: URL) throws {
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let stt = try loadModel()
    var wrong: [(kind: String, voice: String, text: String, heard: String)] = []
    var total = 0
    for voice in voices {
        for (wanted, phrases) in [(true, forRobo), (false, notForRobo)] {
            for (i, text) in phrases.enumerated() {
                guard let audio = try speak(voice, text, out.appendingPathComponent("\(voice)_\(wanted ? 1 : 0)\(i).wav")) else {
                    print("skipping \(voice): not installed")
                    break
                }
                let heard = try stt(audio), request = addressed(heard)
                total += 1
                let ok = (request != nil) == wanted
                print("\(ok ? "ok " : "BAD") \(pad(voice, 9)) \(wanted ? "for robo" : "other  ") | "
                      + "\(pyRepr(text)) -> \(pyRepr(heard)) -> \(pyRepr(request))")
                if !ok { wrong.append((wanted ? "MISS" : "FALSE-POSITIVE", voice, text, heard)) }
            }
        }
    }
    print("\n\(total - wrong.count)/\(total) correct")
    for w in wrong { print("\(pad(w.kind, 14)) \(pad(w.voice, 9)) \(pyRepr(w.text)) => \(pyRepr(w.heard))") }
}

/// Score your clips: `robo_*` must be taken, `other_*` ignored; does each reach the model?
private func scoreClips(_ folder: URL) throws {
    let stt = try Parakeet()
    var wrong: [String] = [], silent: [String] = []
    var total = 0
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".wav") }.sorted()
    for name in names {
        let wanted = name.hasPrefix("robo")
        let audio = try readWav(folder.appendingPathComponent(name))
        let levels = stride(from: 0, to: audio.count / Listen.frame * Listen.frame, by: Listen.frame)
            .map { rms(Array(audio[$0..<$0 + Listen.frame])) }
        let loud = levels.filter { $0 > Listen.minGate }.count
        let heard = try stt(audio), request = addressed(heard)
        total += 1
        let ok = (request != nil) == wanted
        let gate = loud >= Listen.minSpeechFrames ? "" : "  BELOW THE GATE: robo would not listen"
        print("\(ok ? "ok " : "BAD") \(pad(name, 12)) loud frames \(String(format: "%2d", loud)) "
              + "peak \(String(format: "%.3f", levels.max() ?? 0)) | \(pyRepr(heard)) -> \(pyRepr(request))\(gate)")
        if !ok { wrong.append(name) }
        if !gate.isEmpty { silent.append(name) }
    }
    print("\n\(total - wrong.count)/\(total) correct; gate = \(Listen.minGate) RMS, "
          + "\(silent.count) clip(s) below it" + (silent.isEmpty ? "" : ": \(silent.joined(separator: ", "))"))
    if !silent.isEmpty { print("Your voice is quieter than the gate: lower minGate in Listen.swift (try 0.005).") }
}

private let prompts = [("robo", "Robo, what time is it?"), ("robo", "Hey robo, what's due this week?"),
                       ("robo", "Okay robo, plan my day."), ("robo", "What's due tomorrow, robo?"),
                       ("robo", "Robo, I got eight out of ten on the quiz."), ("robo", "Robo."),
                       ("other", "I bought a robot yesterday."), ("other", "The weather is nice today."),
                       ("other", "Let's watch the game tonight."), ("other", "Turn the volume up a little bit.")]

/// 16-bit mono 16 kHz PCM wav of `audio` (what `readWav` and Python's `wave` read).
func writeWav(_ audio: [Float], to url: URL) throws {
    var d = Data()
    func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let bytes = UInt32(audio.count * 2)
    d.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
    put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(Listen.sampleRate)); put(UInt32(Listen.sampleRate * 2))
    put(UInt16(2)); put(UInt16(16)); d.append(contentsOf: Array("data".utf8)); put(bytes)
    for x in audio { put(Int16(max(-32768, min(32767, (x * 32768).rounded())))) }
    try d.write(to: url)
}

/// You read each prompt, as you would to robo, from where you normally sit. `mic` is opened for each
/// prompt, like Python's `sd.rec`; `input` is Enter, or with `wait` the seconds to pause instead.
func recordClips(to out: URL, mic: () throws -> AudioSource, seconds: Double = 4.0, wait: Double? = nil,
                 input: () -> String? = { readLine() }) throws {
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for (i, (kind, text)) in prompts.enumerated() {
        let head = "[\(i + 1)/\(prompts.count)]"
        if let wait {
            print("\(head) Say in \(wait) s: \(pyRepr(text))")
            fflush(stdout)
            Thread.sleep(forTimeInterval: wait)
        } else {
            print("\(head) Press Enter, then say: \(pyRepr(text))  ", terminator: "")
            fflush(stdout)
            guard input() != nil else { throw EvalError(message: "\nno input to read: use --wait SECONDS to record without Enter") }
        }
        let source = try mic()
        defer { source.close() }
        let want = Int(seconds * Double(Listen.sampleRate))
        var audio: [Float] = []
        while audio.count < want {
            guard let frame = try source.read(timeout: 5) else { throw EvalError(message: "the microphone delivered nothing for 5 s") }
            audio += frame
        }
        try writeWav(Array(audio.prefix(want)), to: out.appendingPathComponent(String(format: "%@_%02d.wav", kind, i + 1)))
    }
    print("saved \(prompts.count) clips in \(out.path); now: --wavs \(out.path)")
}

/// The `voice-eval` command: returns the exit status.
public func runVoiceEval(_ args: [String]) -> Int32 {
    do {
        switch args.first {
        case "--record":
            guard args.count == 2 || (args.count == 4 && args[2] == "--wait" && Double(args[3]) != nil) else {
                print("usage: voice-eval --record DIR [--wait SECONDS]")
                return 2
            }
            try recordClips(to: URL(fileURLWithPath: args[1]), mic: { try Microphone() }, wait: args.count == 4 ? Double(args[3]) : nil)
        case "--wavs":
            guard args.count > 1 else { print("usage: voice-eval --wavs DIR"); return 2 }
            try scoreClips(URL(fileURLWithPath: args[1]))
        default:
            try synthetic(URL(fileURLWithPath: args.first ?? "voice_eval"))
        }
        return 0
    } catch let e as EvalError {
        print(e.message)
        return 1
    } catch {
        print("voice-eval failed: \(describe(error))")
        return 1
    }
}
