import AVFoundation
import Foundation
import Testing

@testable import Barktor

struct WAVFileTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("barktor-wavtest-\(UUID().uuidString).wav")
    }

    @Test func roundTripPreservesSamples() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // A 100 Hz ramp keeps every value distinct so an off-by-one or
        // channel-count bug shifts data and fails the comparison.
        let samples: [Float] = (0..<1600).map { Float($0) / 1600.0 - 0.5 }
        try WAVFile.write(samples: samples, to: url)
        let back = try WAVFile.read(url: url)
        #expect(back.count == samples.count)
        #expect(zip(back, samples).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    @Test func readRejectsMissingFile() {
        let url = tempURL()
        #expect(throws: (any Error).self) { try WAVFile.read(url: url) }
    }

    @Test func readRejectsNonFloat32WAV() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // Build a 16 kHz mono Int16 WAV directly: same rate and channel
        // count as Barktor's format, but 16-bit integer on disk. The reader
        // must reject it rather than silently converting to Float32.
        // The writer is scoped so the file is closed (header finalized)
        // before the read attempt.
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                ],
                commonFormat: .pcmFormatInt16, interleaved: true)
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                channels: 1, interleaved: true)!
            let frameCount: AVAudioFrameCount = 160
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
            buffer.frameLength = frameCount
            for i in 0..<Int(frameCount) {
                buffer.int16ChannelData![0][i] = Int16(i * 100)
            }
            try file.write(from: buffer)
        }
        // Specifically WAVFileError: an incidental CoreAudio error (e.g. an
        // unreadable file) must not satisfy this test.
        #expect(throws: WAVFileError.self) { try WAVFile.read(url: url) }
    }
}
