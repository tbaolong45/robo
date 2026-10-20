// The microphone as the listener sees it: 80 ms frames of 16 kHz mono float32 (Python's `Mic`).
import AVFoundation
import Foundation

/// Where the listener gets its audio; tests feed sample arrays through this.
public protocol AudioSource: AnyObject {
    /// One frame of `Listen.frame` samples (-1...1), nil if none came within `timeout` seconds.
    func read(timeout: TimeInterval) throws -> [Float]?
    func close()
}

/// Frames from a producer thread (the audio callback) to `read` on another, none dropped (queue.Queue).
final class FrameQueue {
    private let cond = NSCondition()
    private var frames: [[Float]] = []
    private var pending: [Float] = []

    /// Queue `samples` as `Listen.frame`-sized frames; a remainder waits for the next call.
    func append(samples: [Float]) {
        cond.withLock {
            pending += samples
            while pending.count >= Listen.frame {
                frames.append(Array(pending.prefix(Listen.frame)))
                pending.removeFirst(Listen.frame)
            }
            cond.signal()
        }
    }

    func get(timeout: TimeInterval) -> [Float]? {
        let end = Date(timeIntervalSinceNow: timeout)
        return cond.withLock {
            while frames.isEmpty { if !cond.wait(until: end) { return frames.isEmpty ? nil : frames.removeFirst() } }
            return frames.removeFirst()
        }
    }
}

/// Converts whatever the input device delivers (rate, channels) to 16 kHz mono float32.
final class Resampler {
    private let converter: AVAudioConverter
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Listen.sampleRate),
                                       channels: 1, interleaved: false)!

    init(from format: AVAudioFormat) throws {
        guard let c = AVAudioConverter(from: format, to: target) else {
            throw VoiceError("can't convert \(format) to 16 kHz mono")
        }
        converter = c
    }

    /// The converted samples of `buffer`. The converter keeps its filter state between calls.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

/// A `Resampler` that follows the buffers instead of a format read earlier: the first buffer says what the device delivers, and a later
/// one in another format (a headset joined, the rate changed) gets a new converter. Called from the tap's one queue.
final class AdaptiveResampler {
    private var current: (format: AVAudioFormat, resampler: Resampler)?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if current?.format != buffer.format {
            guard let resampler = try? Resampler(from: buffer.format) else {
                current = nil
                return []  // a format that cannot be converted gives silence, which the listener reports
            }
            current = (buffer.format, resampler)
        }
        return current?.resampler.convert(buffer) ?? []
    }
}

/// The default input device through AVAudioEngine; the tap callback queues frames so none are dropped.
public final class Microphone: AudioSource {
    private let engine = AVAudioEngine()
    private let queue = FrameQueue()

    public init() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError("no input device") }
        let resampler = AdaptiveResampler()
        // No format of our own: `format` above can be stale if the input device changed since it was read (a headset connecting), and
        // installTap then raises an NSException ("Failed to create tap due to format mismatch") that Swift cannot catch: it killed the
        // live app on 2026-10-20. With nil the engine uses the device's format at this moment, and each buffer carries its own.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [queue] buffer, _ in
            queue.append(samples: resampler.convert(buffer))
        }
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    public func read(timeout: TimeInterval) throws -> [Float]? { queue.get(timeout: timeout) }

    public func close() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
