// The microphone path without a microphone: resampling a device's audio to 16 kHz mono frames, and
// the frame queue between the audio callback and the listener.
import AVFoundation
import Foundation
import Testing
@testable import RoboVoice

/// `seconds` of a 440 Hz sine of amplitude 0.5 at `rate` Hz in buffers of `chunk` frames.
func sineBuffers(rate: Double, channels: AVAudioChannelCount, seconds: Double, chunk: Int) -> [AVAudioPCMBuffer] {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    let total = Int(rate * seconds)
    return stride(from: 0, to: total, by: chunk).map { start in
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))!
        buffer.frameLength = AVAudioFrameCount(min(chunk, total - start))
        for c in 0..<Int(channels) {
            for i in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![c][i] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(start + i) / rate))
            }
        }
        return buffer
    }
}

@Test(arguments: [(48000.0, AVAudioChannelCount(1), 4800), (44100.0, AVAudioChannelCount(2), 4410)])
func theDevicesAudioBecomes16kHzMono(rate: Double, channels: AVAudioChannelCount, chunk: Int) throws {
    let buffers = sineBuffers(rate: rate, channels: channels, seconds: 2, chunk: chunk)
    let resampler = try Resampler(from: buffers[0].format)
    let samples = buffers.flatMap { resampler.convert($0) }
    #expect(abs(samples.count - 2 * Listen.sampleRate) < 800)  // the converter's own delay at most
    let steady = Array(samples[4000..<samples.count - 400])
    let rms = (steady.reduce(0) { $0 + $1 * $1 } / Float(steady.count)).squareRoot()
    #expect(abs(Double(rms) - 0.5 / 2.0.squareRoot()) < 0.02)  // the sine's level survives, whatever the channels
    var crossings = 0  // ...and so does its pitch: 440 Hz = 880 zero crossings a second
    for i in 1..<steady.count where (steady[i - 1] < 0) != (steady[i] < 0) { crossings += 1 }
    #expect(abs(Double(crossings) / (Double(steady.count) / 16000) - 880) < 10)
}

@Test func theFrameQueueCutsSamplesIntoFramesAndKeepsTheRemainder() {
    let queue = FrameQueue()
    queue.append(samples: [Float](repeating: 1, count: 3000))
    queue.append(samples: [Float](repeating: 2, count: 840))
    #expect(queue.get(timeout: 0)?.count == Listen.frame)
    #expect(queue.get(timeout: 0)?.count == Listen.frame)
    let third = queue.get(timeout: 0)
    #expect(third?.count == Listen.frame && third?[439] == 1 && third?[440] == 2)  // 3000 - 2 * 1280 = 440
    #expect(queue.get(timeout: 0.01) == nil)  // 840 + 440 more is not yet a frame
}

@Test func theFrameQueueWaitsForAFrame() {
    let queue = FrameQueue()
    Thread.detachNewThread {
        Thread.sleep(forTimeInterval: 0.05)
        queue.append(samples: [Float](repeating: 0.5, count: Listen.frame))
    }
    let t = Date()
    #expect(queue.get(timeout: 2) == [Float](repeating: 0.5, count: Listen.frame))
    #expect(Date().timeIntervalSince(t) < 1)
}
