// NVIDIA Parakeet TDT 0.6B v2 (English), int8 ONNX, run the way onnx-asr runs it on the CPU:
// mel features (NemoPreprocessorNumpy), encoder, greedy TDT decoding, text (models/nemo.py, asr.py).
import Accelerate
import Foundation
import OnnxRuntimeBindings

/// The 128 mel features NeMo models read (onnx-asr `NemoPreprocessorNumpy`), per utterance.
///
/// Not the bundled nemo128.onnx: its float32 STFT moved 8 of 200 TTS transcripts and the name-catch
/// score by one. The FFT here is double precision like numpy's. The model flips a token on
/// differences of 1e-5 in these features (the top mel bands of a voice with no treble hold only the
/// rounding noise of the signal), so every float32 step is the one numpy takes.
struct MelFrontEnd {
    static let nFFT = 512, win = 400, hop = 160, mels = 128
    private let window: [Double]  // Hann(400) centred in 512
    private let filters: [Float]  // `bands` as a dense [257 bins][128 mels] matrix
    private let setup = vDSP_create_fftsetupD(9, FFTRadix(kFFTRadix2))!

    /// onnx-asr's nemo128 filterbank (Slaney mel scale and norm, fbanks.npz), non-zero weights only:
    /// for each mel, its first FFT bin and the weights from there. Taken from the file because
    /// rebuilding it from the formula differs in the last digits of every weight.
    static let bands: [(first: Int, weights: [Float])] = [
        (1, [0.028377542]),
        (1, [0.014389009, 0.013988533]),
        (2, [0.028778018]),
        (3, [0.042366076]),
        (3, [0.0004004761, 0.027977066]),
        (4, [0.014789485, 0.013588057]),
        (5, [0.029178495]),
        (6, [0.0419656]),
        (6, [0.0008009522, 0.02757659]),
        (7, [0.0151899615, 0.013187581]),
        (8, [0.02957897]),
        (9, [0.041565124]),
        (9, [0.0012014282, 0.027176114]),
        (10, [0.015590438, 0.012787105]),
        (11, [0.029979447]),
        (12, [0.041164648]),
        (12, [0.0016019044, 0.026775638]),
        (13, [0.015990913, 0.012386628]),
        (14, [0.030379923]),
        (15, [0.04076417]),
        (15, [0.0020023806, 0.026375161]),
        (16, [0.01639139, 0.011986152]),
        (17, [0.0307804]),
        (18, [0.040363695]),
        (18, [0.0024028565, 0.025974685]),
        (19, [0.016791865, 0.011585677]),
        (20, [0.031180875]),
        (21, [0.03996322]),
        (21, [0.0028033326, 0.02557421]),
        (22, [0.017192341, 0.011185201]),
        (23, [0.03158135]),
        (24, [0.039562743]),
        (24, [0.0032038088, 0.025173733]),
        (25, [0.017592818, 0.010784725]),
        (26, [0.031981826]),
        (27, [0.039162267]),
        (27, [0.003604285, 0.024773257]),
        (28, [0.017993294, 0.010384249]),
        (29, [0.032382302]),
        (30, [0.03876179]),
        (30, [0.004004761, 0.02437278]),
        (31, [0.018320667, 0.01020261]),
        (32, [0.031611487]),
        (33, [0.038553886]),
        (33, [0.0016560329, 0.028360637]),
        (34, [0.010670277, 0.01995563]),
        (35, [0.017961191, 0.013171294]),
        (36, [0.02369182, 0.007852394]),
        (37, [0.028013183, 0.003855225]),
        (38, [0.031065052, 0.0010468618]),
        (39, [0.032976694]),
        (40, [0.03252577]),
        (40, [0.00064701104, 0.030982306]),
        (41, [0.0013818006, 0.03026559]),
        (42, [0.0013279315, 0.030283239, 0.0008534769]),
        (43, [0.00057514827, 0.029303726, 0.00290606]),
        (45, [0.026582016, 0.0054643885]),
        (46, [0.023383716, 0.008459588]),
        (47, [0.019775657, 0.011828544]),
        (48, [0.015819047, 0.015513509]),
        (49, [0.011569872, 0.01946172]),
        (50, [0.007079255, 0.023625057, 0.0026274365]),
        (51, [0.0023938038, 0.022891141, 0.00795073]),
        (53, [0.017088173, 0.013358973]),
        (54, [0.01121673, 0.01881826, 0.00064911996]),
        (55, [0.005309565, 0.023045814, 0.0069843545]),
        (57, [0.01629734, 0.013272314]),
        (58, [0.009608458, 0.019490287, 0.0037686168]),
        (59, [0.003001018, 0.018348109, 0.010636676]),
        (61, [0.011118879, 0.017361937, 0.0030858822]),
        (62, [0.0040415493, 0.017977467, 0.010326529]),
        (64, [0.010409237, 0.017366683, 0.0044033183]),
        (65, [0.0030486379, 0.015703142, 0.011844541]),
        (67, [0.007962661, 0.019040477, 0.0072691003]),
        (68, [0.00047297642, 0.011963892, 0.014769509, 0.0035523723]),
        (70, [0.0041880733, 0.015137954, 0.01130181, 0.000612817]),
        (72, [0.007129859, 0.01756418, 0.0085606435]),
        (74, [0.009372984, 0.016181106, 0.0064749722]),
        (75, [0.0015116623, 0.010986541, 0.014228215, 0.004979082]),
        (77, [0.0030056674, 0.012034435, 0.012825884, 0.0040122336]),
        (79, [0.0039720554, 0.012575715, 0.011917005, 0.0035183341]),
        (81, [0.004466338, 0.012664906, 0.01144886, 0.0034456288]),
        (83, [0.0045397505, 0.012352299, 0.01137282, 0.0037464104]),
        (85, [0.004239538, 0.011684244, 0.011644078, 0.0043767486]),
        (87, [0.0036092235, 0.010703404, 0.012221392, 0.0052962345]),
        (89, [0.0026888547, 0.009449015, 0.013066837, 0.0064677414]),
        (91, [0.0015152441, 0.007957112, 0.014145586, 0.0078572, 0.0015688139]),
        (93, [0.00012218716, 0.006260748, 0.012399308, 0.009433388, 0.003441082]),
        (96, [0.0043902043, 0.010239739, 0.011167733, 0.0054575675]),
        (98, [0.0023731797, 0.007947297, 0.013034129, 0.0075928187, 0.0021515088]),
        (100, [0.00023497004, 0.0055466373, 0.010858304, 0.009823646, 0.0046385336]),
        (103, [0.003060214, 0.0081217885, 0.012128961, 0.0071879826, 0.0022470036]),
        (105, [0.0005084349, 0.005331692, 0.010154949, 0.009781282, 0.0050729434, 0.00036460397]),
        (108, [0.0025059693, 0.0071021295, 0.01169829, 0.00791499, 0.0034283365]),
        (111, [0.0040405965, 0.008420353, 0.010758519, 0.0064831143, 0.0022077088]),
        (113, [0.0009844595, 0.0051580006, 0.009331541, 0.009516308, 0.005442205, 0.0013681013]),
        (116, [0.001923397, 0.0059004324, 0.0098774675, 0.008634379, 0.0047520995, 0.00086981995]),
        (119, [0.0025171568, 0.0063069384, 0.01009672, 0.008075194, 0.0043757064, 0.0006762189]),
        (122, [0.0028022276, 0.0064135725, 0.010024917, 0.0078041027, 0.0042788005, 0.00075349835]),
        (125, [0.0028122822, 0.0062535917, 0.009694901, 0.00778915, 0.0044298316, 0.001070514]),
        (128, [0.0025783663, 0.0058576465, 0.009136926, 0.008000895, 0.004799747, 0.001598598]),
        (131, [0.002129074, 0.0052539534, 0.008378833, 0.008412247, 0.005361819, 0.0023113922]),
        (134, [0.0014907127, 0.0044684615, 0.00744621, 0.008998293, 0.0060914913, 0.0031846897, 0.0002778881]),
        (137, [0.0006874594, 0.0035250045, 0.00636255, 0.009200095, 0.0069662277, 0.004196289, 0.00142635]),
        (141, [0.0024454482, 0.005149391, 0.007853334, 0.007965373, 0.0053258534, 0.0026863334, 4.6813497e-05]),
        (144, [0.0012498229, 0.0038264545, 0.006403086, 0.008979717, 0.0065547833, 0.004039542, 0.0015243003]),
        (148, [0.0024117676, 0.004867082, 0.007322396, 0.007866095, 0.0054692803, 0.0030724655, 0.0006756509]),
        (151, [0.0009217858, 0.0032614947, 0.0056012035, 0.007940913, 0.006960341, 0.004676377, 0.002392413, 0.00010844924]),
        (155, [0.0016010479, 0.0038305947, 0.0060601416, 0.008289688, 0.0063224705, 0.004146044, 0.0019696178]),
        (159, [0.0020236908, 0.004148262, 0.006272834, 0.0079984525, 0.0059245005, 0.0038505483, 0.0017765962]),
        (162, [0.00019237598, 0.002216915, 0.004241454, 0.0062659928, 0.007716905, 0.005740602, 0.003764299, 0.001787996]),
        (166, [0.00027660435, 0.0022058205, 0.004135037, 0.006064253, 0.007630208, 0.005746957, 0.0038637053, 0.0019804542, 9.720283e-05]),
        (170, [0.00017516538, 0.0020135469, 0.0038519285, 0.00569031, 0.0075286916, 0.0059216237, 0.004127043, 0.002332462, 0.00053788116]),
        (175, [0.0016614045, 0.0034132283, 0.005165052, 0.006916876, 0.006244412, 0.0045343265, 0.002824241, 0.0011141557]),
        (179, [0.0011689977, 0.0028383392, 0.004507681, 0.006177022, 0.006696761, 0.005067193, 0.0034376248, 0.0018080564, 0.00017848812]),
        (183, [0.0005543412, 0.0021450839, 0.0037358266, 0.0053265695, 0.0069173123, 0.0057087895, 0.0041559474, 0.0026031053, 0.0010502631]),
        (188, [0.0013498128, 0.0028656577, 0.004381502, 0.005897347, 0.006443671, 0.0049639423, 0.0034842135, 0.0020044846, 0.0005247561]),
        (192, [0.00046750545, 0.0019119786, 0.0033564519, 0.004800925, 0.006245398, 0.0058476427, 0.004437585, 0.0030275274, 0.0016174696, 0.00020741203]),
        (197, [0.0008883274, 0.0022647895, 0.0036412515, 0.0050177136, 0.006394176, 0.0054506254, 0.0041069584, 0.0027632914, 0.0014196245, 7.5957636e-05]),
        (202, [0.0011187159, 0.0024303691, 0.0037420222, 0.0050536753, 0.0063653286, 0.0052314554, 0.0039510536, 0.0026706513, 0.0013902491, 0.00010984701]),
        (207, [0.0011792389, 0.0024291347, 0.0036790303, 0.004928926, 0.006178822, 0.0051706103, 0.0039504943, 0.0027303782, 0.0015102623, 0.00029014613]),
        (212, [0.001088865, 0.002279911, 0.0034709568, 0.004662003, 0.005853049, 0.0052500986, 0.00408743, 0.0029247615, 0.001762093, 0.0005994245]),
        (217, [0.0008650696, 0.0020000369, 0.0031350038, 0.004269971, 0.0054049385, 0.0054533565, 0.004345431, 0.003237505, 0.0021295792, 0.0010216534]),
        (222, [0.0005239366, 0.0016054653, 0.0026869942, 0.0037685228, 0.0048500514, 0.005765153, 0.0047093923, 0.0036536318, 0.0025978712, 0.0015421107, 0.00048635007]),
        (227, [8.0251666e-05, 0.001110858, 0.0021414645, 0.0031720707, 0.004202677, 0.0052332836, 0.0051654456, 0.0041593937, 0.0031533425, 0.002147291, 0.0011412395, 0.000135188]),
        (233, [0.0005296727, 0.0015117544, 0.002493836, 0.0034759177, 0.0044579995, 0.005440081, 0.004742188, 0.0037835052, 0.0028248222, 0.0018661394, 0.00090745644]),
        (239, [0.00081008807, 0.0017459297, 0.0026817713, 0.0036176129, 0.0045534545, 0.0053904755, 0.004476931, 0.0035633866, 0.002649842, 0.0017362974, 0.0008227529]),
        (244, [4.765147e-05, 0.0009394302, 0.0018312089, 0.0027229877, 0.0036147665, 0.004506545, 0.005223179, 0.004352647, 0.0034821155, 0.002611584, 0.0017410525, 0.000870521]),
    ]

    init() {
        let m = Self.win
        let hann = (0..<m).map { 0.5 + 0.5 * cos(Double.pi * Double(2 * $0 - (m - 1)) / Double(m - 1)) }
        window = [Double](repeating: 0, count: (Self.nFFT - m) / 2) + hann
            + [Double](repeating: 0, count: (Self.nFFT - m) / 2)
        var f = [Float](repeating: 0, count: (Self.nFFT / 2 + 1) * Self.mels)
        for (j, band) in Self.bands.enumerated() {
            for (i, w) in band.weights.enumerated() { f[(band.first + i) * Self.mels + j] = w }
        }
        filters = f
    }

    /// Power spectrum (257 bins) of one windowed 512-sample frame.
    private func power(_ frame: [Double]) -> [Float] {
        var re = [Double](repeating: 0, count: 256), im = re
        var out = [Float](repeating: 0, count: 257)
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPDoubleSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                frame.withUnsafeBufferPointer { p in
                    p.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: 256) {
                        vDSP_ctozD($0, 2, &split, 1, 256)
                    }
                }
                vDSP_fft_zripD(setup, &split, 1, 9, FFTDirection(kFFTDirection_Forward))
                // packed real FFT, scaled by 2: bin 0 is DC in re[0], bin 256 is Nyquist in im[0]
                let mag = { (a: Double, b: Double) -> Float in Float((a * a + b * b).squareRoot() / 2) }
                out[0] = mag(r[0], 0); out[256] = mag(i[0], 0)
                for k in 1..<256 { out[k] = mag(r[k], i[k]) }
            }
        }
        return out.map { $0 * $0 }  // numpy: abs(...).astype(float32) ** 2
    }

    /// Features as [128 mels][frames + 1] (the model gets the extra, zeroed column), and `length`:
    /// the frames that count.
    func features(_ audio: [Float]) -> (data: [Float], columns: Int, length: Int) {
        let n = audio.count, length = n / Self.hop, columns = length + 1
        var x = audio  // pre-emphasis 0.97
        for i in stride(from: n - 1, to: 0, by: -1) { x[i] = audio[i] - Float(0.97) * audio[i - 1] }
        let padded = [Float](repeating: 0, count: Self.nFFT / 2) + x + [Float](repeating: 0, count: Self.nFFT / 2)
        var spectrum = [Float](repeating: 0, count: columns * 257)
        var frame = [Double](repeating: 0, count: Self.nFFT)
        for t in 0..<columns {
            for k in 0..<Self.nFFT { frame[k] = Double(padded[t * Self.hop + k]) * window[k] }
            spectrum.replaceSubrange(t * 257..<(t + 1) * 257, with: power(frame))
        }
        // a dense float32 product, as numpy's matmul (a sparse sum in bin order moved the top mel bands by 6e-5)
        var mel = [Float](repeating: 0, count: columns * Self.mels)
        vDSP_mmul(spectrum, 1, filters, 1, &mel, 1, vDSP_Length(columns), vDSP_Length(Self.mels), 257)
        let guardValue = Float(sign: .plus, exponent: -24, significand: 1)  // numpy's log zero guard, 2**-24
        for i in mel.indices { mel[i] = Float(log(Double(mel[i] + guardValue))) }
        // per-feature mean and standard deviation over the `length` real frames
        var mean = [Float](repeating: 0, count: Self.mels), variance = mean
        for t in 0..<length { for j in 0..<Self.mels { mean[j] += mel[t * Self.mels + j] } }
        for j in 0..<Self.mels { mean[j] /= Float(length) }
        for t in 0..<length {
            for j in 0..<Self.mels { let d = mel[t * Self.mels + j] - mean[j]; variance[j] += d * d }
        }
        let deviation = variance.map { ($0 / Float(length - 1)).squareRoot() + 1e-5 }
        var out = [Float](repeating: 0, count: Self.mels * columns)
        for t in 0..<length {
            for j in 0..<Self.mels { out[j * columns + t] = (mel[t * Self.mels + j] - mean[j]) / deviation[j] }
        }
        return (out, columns, length)
    }
}

/// onnx-asr's `re.sub(r"\A\s|\s\B|(\s)\b", ...)` on the joined tokens: no space at the start or
/// before a non-word character, one space before a word.
func spaced(_ text: String) -> String {
    let c = Array(text.unicodeScalars)
    var out = String.UnicodeScalarView()
    for (i, ch) in c.enumerated() {
        if !ch.properties.isWhitespace { out.append(ch) } else if i > 0, i + 1 < c.count, isWord(c[i + 1]) {
            out.append(" ")
        }
    }
    return String(out)
}

/// The tokens of a `vocab.txt` ("<token> <id>" per line) by id, "\u{2581}" turned into a space.
func vocabulary(_ text: String) throws -> [String] {
    let lines = text.split(separator: "\n")
    var tokens = [String](repeating: "", count: lines.count)
    for (n, line) in lines.enumerated() {
        guard let space = line.lastIndex(of: " "), let id = Int(line[line.index(after: space)...]), tokens.indices.contains(id) else {
            throw VoiceError("the speech model's vocab.txt line \(n + 1) is not \"<token> <id>\" with an id below \(lines.count)")
        }
        tokens[id] = line[..<space].replacingOccurrences(of: "\u{2581}", with: " ")
    }
    return tokens
}

/// The two ONNX sessions and the vocabulary; everything runs on `CPUExecutionProvider`.
final class ParakeetModel {
    static let blank = 1024, vocabSize = 1025, durations = 5, maxTokensPerStep = 10
    static let stateShape = [2, 1, 640]  // the prediction network's two LSTM states
    private let env: ORTEnv
    private let encoder: ORTSession, decoder: ORTSession
    private let vocab: [String]  // "\u{2581}" already turned into a space
    private let mel = MelFrontEnd()

    init(directory: URL) throws {
        func file(_ name: String) throws -> String {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VoiceError("the speech model is incomplete: \(url.path) is missing")
            }
            return url.path
        }
        let tokens = try vocabulary(String(contentsOfFile: file("vocab.txt"), encoding: .utf8))  // before the slow part
        guard tokens.count == Self.vocabSize, tokens[Self.blank] == "<blk>" else {
            throw VoiceError("the speech model's vocabulary is not Parakeet TDT v2's")
        }
        // onnxruntime 1.30+ opens a connection to a Microsoft server to report usage unless this is
        // set before it starts; robo is an offline assistant.
        setenv("ORT_DISABLE_TELEMETRY", "1", 1)
        // CPU only: the CoreML provider (macOS default in onnxruntime) loads 3x slower, runs 2x
        // slower and hears differently (fp16). No provider is appended, so ORT keeps its CPU one.
        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        // onnxruntime 1.30 keeps the encoder weights twice (the file's copy and the kernels' packed
        // one): ~1.4 GB instead of ~0.8 GB (1.31 frees the first). Packing on every call costs
        // ~15-20 ms per clip and changes no transcript. Remove with a 1.31 pod (checked 2026-10-13).
        try options.addConfigEntry(withKey: "session.disable_prepacking", value: "1")
        encoder = try ORTSession(env: env, modelPath: file("encoder-model.int8.onnx"), sessionOptions: options)
        decoder = try ORTSession(env: env, modelPath: file("decoder_joint-model.int8.onnx"), sessionOptions: options)
        vocab = tokens
    }

    private func tensor<T>(_ values: [T], _ shape: [Int], _ type: ORTTensorElementDataType) throws -> ORTValue {
        let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
        return try ORTValue(tensorData: data, elementType: type, shape: shape.map { NSNumber(value: $0) })
    }

    private func floats(_ value: ORTValue) throws -> [Float] {
        let data = try value.tensorData()
        return Array(UnsafeBufferPointer(start: data.bytes.assumingMemoryBound(to: Float.self), count: data.length / 4))
    }

    /// The text of 16 kHz mono `audio`, as onnx-asr's `recognize` writes it (no levelling, no strip).
    func transcribe(_ audio: [Float]) throws -> String {
        if audio.count < MelFrontEnd.hop { return "" }  // no feature frame (Python gives "" or raises IndexError)
        let tokens = try decode(encode(mel.features(audio)))
        return spaced(tokens.map { vocab[$0] }.joined())
    }

    /// The encoder's `out` as [1024 channels][columns]; the first `steps` columns count.
    func encode(_ f: (data: [Float], columns: Int, length: Int)) throws -> (out: [Float], columns: Int, steps: Int) {
        let encoded = try encoder.run(
            withInputs: ["audio_signal": tensor(f.data, [1, MelFrontEnd.mels, f.columns], .float),
                         "length": tensor([Int64(f.length)], [1], .int64)],
            outputNames: ["outputs", "encoded_lengths"], runOptions: nil)
        let columns = try encoded["outputs"]!.tensorTypeAndShapeInfo().shape[2].intValue
        let steps = try encoded["encoded_lengths"]!.tensorData().bytes.load(as: Int64.self)
        return (try floats(encoded["outputs"]!), columns, Int(steps))
    }

    /// Greedy TDT decoding: each step emits a token (or blank) and how many frames to skip.
    func decode(_ encoded: (out: [Float], columns: Int, steps: Int)) throws -> [Int] {
        let (out, columns, steps) = encoded
        var tokens: [Int] = [], t = 0, emitted = 0
        let zeros = [Float](repeating: 0, count: Self.stateShape.reduce(1, *))
        var state1 = try tensor(zeros, Self.stateShape, .float), state2 = try tensor(zeros, Self.stateShape, .float)
        var frame = [Float](repeating: 0, count: 1024)
        while t < steps {
            for c in 0..<1024 { frame[c] = out[c * columns + t] }
            let step = try decoder.run(
                withInputs: ["encoder_outputs": tensor(frame, [1, 1024, 1], .float),
                             "targets": tensor([Int32(tokens.last ?? Self.blank)], [1, 1], .int32),
                             "target_length": tensor([Int32(1)], [1], .int32),
                             "input_states_1": state1, "input_states_2": state2],
                outputNames: ["outputs", "output_states_1", "output_states_2"], runOptions: nil)
            let logits = try floats(step["outputs"]!)
            let token = logits[..<Self.vocabSize].indices.reduce(0) { logits[$1] > logits[$0] ? $1 : $0 }
            let skip = (Self.vocabSize..<Self.vocabSize + Self.durations).reduce(Self.vocabSize) {
                logits[$1] > logits[$0] ? $1 : $0 } - Self.vocabSize
            if token != Self.blank {
                state1 = step["output_states_1"]!; state2 = step["output_states_2"]!
                tokens.append(token)
                emitted += 1
            }
            if skip > 0 {
                t += skip; emitted = 0
            } else if token == Self.blank || emitted == Self.maxTokensPerStep {
                t += 1; emitted = 0
            }
        }
        return tokens
    }
}

/// Parakeet TDT 0.6B v2 on this laptop. Loads in a second or two from the Hugging Face cache
/// (~650 MB, downloaded once by the Python app: this port does not download).
public final class Parakeet {
    private let recognize: ([Float]) throws -> String

    /// The model in `directory` (encoder, decoder_joint, vocab.txt), or the Hugging Face cache's.
    public init(directory: URL? = nil) throws {
        let model = try ParakeetModel(directory: try directory ?? Self.cachedModel())
        recognize = model.transcribe
    }

    init(recognize: @escaping ([Float]) throws -> String) { self.recognize = recognize }  // tests

    /// The snapshot of `istupakov/parakeet-tdt-0.6b-v2-onnx` that ~/.cache/huggingface/hub points `main` at.
    static func cachedModel() throws -> URL {
        let repo = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--istupakov--parakeet-tdt-0.6b-v2-onnx")
        guard let revision = try? String(contentsOf: repo.appendingPathComponent("refs/main"), encoding: .utf8) else {
            throw VoiceError("the speech model is not downloaded yet (expected in \(repo.path)); "
                             + "start the Python robo once to fetch it")
        }
        return repo.appendingPathComponent("snapshots/\(trimmed(revision))")
    }

    /// What is said in 16 kHz mono `audio`, levelled first (soft speech is read worse).
    public func callAsFunction(_ audio: [Float]) throws -> String { trimmed(try recognize(leveled(audio))) }
}
