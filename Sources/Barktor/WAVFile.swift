import AVFoundation
import Foundation

enum WAVFileError: Error {
    case unsupportedFormat(String)
    case emptyFile
}

// Minimal WAV I/O for the dictation history: everything Barktor records is
// already 16 kHz mono Float32, so this reads/writes exactly that shape and
// refuses anything else rather than resampling (drag-and-drop transcription
// of arbitrary files is a separate backlog feature).
enum WAVFile {
    static let sampleRate: Double = 16_000

    static func write(samples: [Float], to url: URL) throws {
        guard !samples.isEmpty else { throw WAVFileError.emptyFile }
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                channels: 1, interleaved: false)
        else { throw WAVFileError.unsupportedFormat("could not build 16kHz mono format") }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw WAVFileError.unsupportedFormat("could not allocate buffer") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    static func read(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        // Validate the on-disk format (fileFormat): processingFormat is the
        // canonicalized in-memory format and always reports Float32 for PCM,
        // so it would silently accept e.g. a 16-bit integer WAV.
        let disk = file.fileFormat
        guard
            disk.sampleRate == sampleRate, disk.channelCount == 1,
            disk.commonFormat == .pcmFormatFloat32
        else {
            throw WAVFileError.unsupportedFormat(
                "expected 16kHz mono Float32, got \(disk.sampleRate)Hz "
                    + "\(disk.channelCount)ch commonFormat=\(disk.commonFormat.rawValue)")
        }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { throw WAVFileError.emptyFile }
        guard
            let bufferFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                channels: 1, interleaved: false)
        else { throw WAVFileError.unsupportedFormat("could not build 16kHz mono format") }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: bufferFormat, frameCapacity: frames)
        else { throw WAVFileError.unsupportedFormat("could not allocate buffer") }
        try file.read(into: buffer)
        return Array(
            UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
