// The Parakeet pipeline: levelling before the model, the numpy-exact mel front end, the text rules,
// and (when the model is in the Hugging Face cache) real transcripts equal to Python's onnx-asr.
import AVFoundation
import Foundation
import Testing
@testable import RoboVoice

@Test func parakeetLoadsOnTheCPUOnly() throws {
    // ORT keeps its CPU provider unless one is appended; CoreML loads 3x slower, runs 2x slower and hears differently
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/RoboVoice")
    let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }
    #expect(files.count >= 4)
    for file in files {
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("appendExecutionProvider"), "\(file.lastPathComponent)")
    }
}

@Test func parakeetHearsEveryUtteranceAtTheSameLevel() throws {
    let heard = Log<[Float]>()
    let stt = Parakeet(recognize: { heard.append($0); return " ok " })
    #expect(try stt(sine(0.05)) == "ok")
    #expect(abs(heard.all[0].map(abs).max()! - Float(Listen.levelPeak)) <= 0.05 * Float(Listen.levelPeak))
}

/// onnx-asr's NemoPreprocessorNumpy on a signal both sides can build exactly: the model flips a token
/// on differences of 1e-5, so these must stay this close (the first and last frames are the edge cases).
@Test func melFeaturesAreNumpys() {
    let audio = (0..<8000).map { Float(($0 * 7919) % 2003 - 1001) / 20000 }
    let f = MelFrontEnd().features(audio)
    #expect(f.columns == 51 && f.length == 50)
    let golden: [(mel: Int, frame: Int, want: Float)] = [
        (0, 0, 1.0270934104919434), (0, 10, -1.649157166481018), (5, 3, -0.5817433595657349),
        (64, 10, -0.37773263454437256), (100, 49, 1.211790680885315), (127, 0, -4.6962175369262695),
        (127, 49, 1.0410276651382446), (31, 25, 0.08310115337371826), (60, 50, 0.0),  // the extra column is zero
    ]
    for g in golden { #expect(abs(f.data[g.mel * f.columns + g.frame] - g.want) < 2e-5, "mel \(g.mel) frame \(g.frame)") }
    #expect(abs(f.data.reduce(0.0) { $0 + Double($1) } - -0.008072077471297234) < 1e-3)
    #expect(abs(f.data.reduce(0.0) { $0 + Double(abs($1)) } - 4840.541058388713) < 0.1)
}

@Test func melFilterbankIsOnnxAsrs() {
    let bands = MelFrontEnd.bands
    #expect(bands.count == 128 && bands.allSatisfy { $0.first >= 1 && $0.first + $0.weights.count <= 257 })
    #expect(bands.reduce(0) { $0 + $1.weights.count } == 504)
    #expect(abs(bands.flatMap { $0.weights }.reduce(0.0) { $0 + Double($1) } - 4.090487627036055) < 1e-9)  // fbanks.npz["nemo128"]
}

@Test(arguments: [
    (" hello  world ,  how are you ?", "hello world, how are you?"), (" Robo , what's  up", "Robo, what's up"),
    (" a  b ", "a b"), (" 'quoted' word", "'quoted' word"), (" ", ""), ("  x", " x"),
    (" don't stop-now . ok", "don't stop-now. ok"), (" 3 . 5 percent", "3. 5 percent"),
    (" café  au lait", "café au lait"), (" (a) [b] {c}", "(a)[b]{c}"), (" \"hi\" he said", "\"hi\" he said"),
    (" rubble ... was", "rubble... was"), ("x ", "x"), ("a  ,b", "a,b"), (" _ under", "_ under"),
])
func tokensBecomeTextAsInOnnxAsr(joined: String, text: String) {  // re.sub(r"\A\s|\s\B|(\s)\b", ...)
    #expect(spaced(joined) == text)
}

// MARK: - the real model

let modelCached = (try? Parakeet.cachedModel()).map {
    FileManager.default.fileExists(atPath: $0.appendingPathComponent("encoder-model.int8.onnx").path)
} ?? false

let sayLock = NSLock()

/// `say`'s 16 kHz mono audio of `text` in `voice` with a little silence around it, as voice_eval makes it.
func spoken(_ voice: String, _ text: String) throws -> [Float] {
    let wav = FileManager.default.temporaryDirectory.appendingPathComponent("robo-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: wav) }
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", voice, "-o", wav.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
    sayLock.lock()  // several `say` at once under load left macOS's speech service stuck for ever
    defer { sayLock.unlock() }
    try say.run()
    let end = Date(timeIntervalSinceNow: 60)
    while say.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
    if say.isRunning { say.terminate(); throw VoiceError("say did not finish in 60 s") }
    let silence = [Float](repeating: 0, count: 8000)
    return try silence + readWav(wav) + silence
}

/// What Python's `listen.Parakeet()(audio)` (onnx-asr 0.12, onnxruntime 1.31) wrote for the same `say` clips.
@Test(.enabled(if: modelCached), arguments: [
    ("Samantha", "Robo, what time is it?", "Robo, what time is it?"),
    ("Daniel", "What's due this week, robo?", "What's due this week, Robo?"),
    ("Karen", "Rubble was everywhere after the storm.", "Rubble was everywhere after the storm."),
    ("Moira", "Can you help me with my homework, robo?", "Can you help me with my homework, Robo?"),
    ("Tessa", "Robots are interesting.", "Robots are interesting."),
    ("Samantha", "Robo, I got eight out of ten on the quiz.", "Robo, I got 8 out of 10 on the quiz."),
])
func parakeetWritesWhatPythonsOnnxAsrWrites(voice: String, said: String, python: String) throws {
    let stt = try shared.get()
    #expect(try stt(spoken(voice, said)) == python)
}

/// One model for the tests that need it (loading takes about a second).
let shared = Result { try Parakeet() }

// MARK: - a broken model folder or clip is an error, not a crash

/// A model folder with the cached encoder and decoder and this `vocab.txt`, for the body only.
func withModelFolder<T>(vocab: String, _ body: (URL) throws -> T) throws -> T {
    let real = try Parakeet.cachedModel()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("robo-model-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for name in ["encoder-model.int8.onnx", "decoder_joint-model.int8.onnx"] {
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(name),
                                                   withDestinationURL: real.appendingPathComponent(name))
    }
    try vocab.write(to: dir.appendingPathComponent("vocab.txt"), atomically: true, encoding: .utf8)
    return try body(dir)
}

let brokenVocabularies = [
    "<unk> 0\nnot-a-token-line\n<blk> 2\n",  // no space
    "<unk> 0\n\u{2581}t one\n<blk> 2\n",  // the id is not a number
    "<unk> 0\n\u{2581}t 7\n<blk> 2\n",  // the id is past the end of the table
    "<unk> 0\n\u{2581}t -1\n<blk> 2\n",  // ...or before its start
    "<unk> 0\n\u{2581}t 1\n<blk> \n",  // the id is missing
]

@Test(.enabled(if: modelCached), arguments: brokenVocabularies)
func aMalformedVocabularyThrows(vocab: String) throws {
    _ = try withModelFolder(vocab: vocab) { dir in
        #expect(throws: VoiceError.self) { try Parakeet(directory: dir) }
    }
}

@Test(.enabled(if: modelCached)) func aMalformedVocabularyIsReportedByTheListenerNotACrash() throws {
    try withModelFolder(vocab: brokenVocabularies[0]) { dir in
        let events = Events()
        let lis = listener(events, mic: { FakeMic() }, stt: { try Parakeet(directory: dir).callAsFunction })
        #expect(lis.start())
        let note = Events.note(events.get())
        #expect(note?.hasPrefix("I can't load speech recognition: ") == true)
        #expect(eventually { !lis.running })
    }
}

@Test func levellingNothingIsNothing() {
    #expect(leveled([]).isEmpty)
    #expect(percentile([Double](), 99.5) == 0 && percentile([Float](), 20) == 0)
    #expect(speechGate([]) == Listen.minGate)
}

/// Python raises IndexError for an empty clip; here it is heard as nothing, like the clips shorter
/// than one 10 ms feature frame that Python writes "" for.
@Test(.enabled(if: modelCached), arguments: [0, 1, 100, 159])
func aClipShorterThanOneFeatureFrameIsHeardAsNothing(samples: Int) throws {
    #expect(try shared.get()([Float](repeating: 0.1, count: samples)) == "")
}
