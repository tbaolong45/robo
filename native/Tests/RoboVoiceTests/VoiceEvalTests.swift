// voice_eval's output format and its wav reader: a bad or empty clip is an error or a plain line, not a crash.
import Foundation
import Testing
@testable import RoboVoice

@Test func voiceEvalPrintsPythonsRepr() {
    #expect(pyRepr("Robo, what time is it?") == "'Robo, what time is it?'")
    #expect(pyRepr("What's due") == "\"What's due\"")
    #expect(pyRepr("it's \"x\"") == "'it\\'s \"x\"'")
    #expect(pyRepr("a\nb\\") == "'a\\nb\\\\'")
    #expect(pyRepr(nil) == "None" && pyRepr("") == "''")
}

func le(_ v: Int, bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8((v >> (8 * $0)) & 0xff) } }

/// A RIFF/WAVE file made of `chunks` (id, payload); `cut` drops that many bytes from the end.
func wav(_ chunks: [(String, [UInt8])], cut: Int = 0) -> Data {
    var body = Array("WAVE".utf8)
    for (id, payload) in chunks { body += Array(id.utf8) + le(payload.count, bytes: 4) + payload + (payload.count % 2 == 1 ? [0] : []) }
    return Data((Array("RIFF".utf8) + le(body.count, bytes: 4) + body).dropLast(cut))
}

/// A `fmt ` chunk payload: PCM, `channels`, `rate`, 16 bits.
func format(rate: Int = 16000, channels: Int = 1) -> [UInt8] {
    le(1, bytes: 2) + le(channels, bytes: 2) + le(rate, bytes: 4) + le(rate * channels * 2, bytes: 4)
        + le(channels * 2, bytes: 2) + le(16, bytes: 2)
}

/// `data` written to a temporary file called `name`, in a folder of its own that `body` gets.
@discardableResult func withWav<T>(_ data: Data, name: String = "clip.wav", _ body: (URL, URL) throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("robo-wav-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try data.write(to: dir.appendingPathComponent(name))
    return try body(dir, dir.appendingPathComponent(name))
}

@Test func readWavReadsSixteenBitMonoAt16kHz() throws {
    let samples = le(0, bytes: 2) + le(16384, bytes: 2) + le(0x8000, bytes: 2)
    try withWav(wav([("fmt ", format()), ("data", samples)])) { _, url in
        let audio = try readWav(url)
        #expect(audio == [0, 0.5, -1])
    }
}

@Test func readWavAcceptsAnEmptyClip() throws {
    try withWav(wav([("fmt ", format()), ("data", [])])) { _, url in
        let audio = try readWav(url)
        #expect(audio.isEmpty)
    }
}

@Test(arguments: [1, 6, 15, 16])  // the file ends `cut` bytes short of the fmt chunk's 16, even before its first byte
func readWavSaysWhenTheFmtChunkIsTruncated(cut: Int) throws {
    try withWav(wav([("fmt ", format())], cut: cut)) { _, url in
        #expect { try readWav(url) } throws: { ($0 as? EvalError)?.message.contains("fmt") == true }
    }
}

@Test func readWavRefusesOtherFormats() throws {
    try withWav(wav([("fmt ", format(rate: 44100)), ("data", le(1, bytes: 2))])) { _, url in
        #expect { try readWav(url) } throws: { ($0 as? EvalError)?.message.contains("16 kHz mono 16-bit") == true }
    }
}

@Test func readWavSurvivesGarbage() throws {
    for data in [Data(), Data("RIFF".utf8), Data(repeating: 0xff, count: 40), wav([("fmt ", format())])] {  // the last has no audio
        try withWav(data) { _, url in #expect(throws: EvalError.self) { try readWav(url) } }
    }
}

@Test(.enabled(if: modelCached)) func scoringAnEmptyOrTinyClipPrintsALineAndGoesOn() throws {
    let empty = wav([("fmt ", format()), ("data", [])])
    try withWav(empty, name: "robo_empty.wav") { dir, _ in
        try wav([("fmt ", format()), ("data", [UInt8](repeating: 1, count: 200))])
            .write(to: dir.appendingPathComponent("other_tiny.wav"))
        #expect(runVoiceEval(["--wavs", dir.path]) == 0)
    }
}

// MARK: - --record

/// A mic that plays `samples` in frames, then reports silence (nil) on every read.
final class PlayMic: AudioSource {
    private var frames: [[Float]]
    private(set) var closed = false
    init(_ samples: [Float]) {
        frames = stride(from: 0, to: samples.count, by: Listen.frame).map { Array(samples[$0..<min($0 + Listen.frame, samples.count)]) }
    }
    func read(timeout: TimeInterval) throws -> [Float]? { frames.isEmpty ? nil : frames.removeFirst() }
    func close() { closed = true }
}

/// A temporary folder path that does not exist yet.
func freshFolder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("robo-rec-\(UUID().uuidString)") }

@Test func recordWritesTenPromptedClipsThatReadWavReadsBack() throws {
    let out = freshFolder()
    defer { try? FileManager.default.removeItem(at: out) }
    let mics = Log<PlayMic>()
    let asked = Log<Int>()
    try recordClips(to: out, mic: {  // the n-th opening hears a sine whose amplitude is n/20
        let n = mics.all.count + 1
        let mic = PlayMic(sine(Float(n) / 20, 70000))  // more than the 4 s it keeps
        mics.append(mic)
        return mic
    }, input: { asked.append(1); return "" })
    let names = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
    #expect(names == ["other_07.wav", "other_08.wav", "other_09.wav", "other_10.wav",
                      "robo_01.wav", "robo_02.wav", "robo_03.wav", "robo_04.wav", "robo_05.wav", "robo_06.wav"])
    #expect(asked.all.count == 10 && mics.all.allSatisfy { $0.closed })
    let clip = try readWav(out.appendingPathComponent("robo_03.wav"))
    #expect(clip.count == 4 * Listen.sampleRate)  // exactly 4 s, as sd.rec(int(4.0 * 16000))
    #expect(abs(clip.map(abs).max()! - 3.0 / 20) < 1e-3)
}

@Test func writeWavRoundTripsAndClips() throws {
    let out = freshFolder()
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: out) }
    let url = out.appendingPathComponent("x.wav")
    try writeWav([0, 0.5, -0.5, 1, -1, 2, -2], to: url)
    #expect(try readWav(url) == [0, 0.5, -0.5, 32767.0 / 32768, -1, 32767.0 / 32768, -1])
    #expect(try Data(contentsOf: url).count == 44 + 14)
}

@Test func recordWithoutAnInputStreamNeedsWait() {
    let out = freshFolder()
    defer { try? FileManager.default.removeItem(at: out) }
    #expect { try recordClips(to: out, mic: { PlayMic([]) }, input: { nil }) } throws: {
        ($0 as? EvalError)?.message.contains("--wait") == true
    }
}

@Test func recordWithWaitDoesNotReadInputAndSaysWhatTheMicDoesNotDeliver() throws {
    let out = freshFolder()
    defer { try? FileManager.default.removeItem(at: out) }
    #expect { try recordClips(to: out, mic: { PlayMic(sine(0.1, 8000)) }, wait: 0, input: { Issue.record("read stdin"); return nil }) } throws: {
        ($0 as? EvalError)?.message.contains("microphone") == true  // 0.5 s of audio is not 4 s
    }
}

@Test func recordOpensNoMicrophoneForBadArguments() {
    #expect(runVoiceEval(["--record"]) == 2)
}
