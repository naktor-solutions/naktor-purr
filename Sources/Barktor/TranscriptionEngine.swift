import Foundation

// Common surface for every speech-to-text backend we ship: batch
// `transcribe(samples:)` and streaming `makeStreamingSession()`.
//
// Engines that don't support streaming (currently Whisper) throw
// `EngineError.streamingNotSupported`; the coordinator transparently falls
// back to batch mode for those.
protocol TranscriptionEngine: AnyObject {
    var supportsStreaming: Bool { get }

    func warmup() async
    func transcribe(samples: [Float]) async throws -> String
    // Batch transcription that also carries per-token timings, for callers
    // (meeting mode) that align text against diarized speaker segments.
    func transcribeDetailed(samples: [Float]) async throws -> DetailedTranscription
    func makeStreamingSession() async throws -> any StreamingSession
}

// Events from a live dictation session, in arrival order:
//
// * `.partial(suffix:)` — verbatim new tokens since the last partial.
//   Append-only with the model's native spacing.
// * `.endOfUtterance(rawAccumulated:)` — silence boundary or final
//   flush. The consumer subtracts the previous boundary's raw text to
//   isolate the just-completed utterance, runs PostProcessor, and
//   reconciles the typed text in place.
//
// Single AsyncStream guarantees ordering between partial typing and
// EOU corrections.
enum StreamingEvent: Equatable {
    case partial(suffix: String)
    case endOfUtterance(rawAccumulated: String)
}

protocol StreamingSession: AnyObject {
    var events: AsyncStream<StreamingEvent> { get }
    func feed(samples: [Float]) async throws
    func finish() async throws
    func cancel() async
}
