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
    // True once the model is resident and transcribe() won't pay the load /
    // ANE-compile cost. Lets the UI show "Warming up…" instead of a misleading
    // "Transcribing" during a cold first run.
    func isWarm() async -> Bool
    func transcribe(samples: [Float]) async throws -> String
    // Batch transcription that also carries per-token timings, for callers
    // (meeting mode) that align text against diarized speaker segments.
    func transcribeDetailed(samples: [Float]) async throws -> DetailedTranscription
    func makeStreamingSession() async throws -> any StreamingSession

    // Progress-reporting variants for long batch runs (the background queue).
    // fraction ∈ [0, 1]. Engines with no real signal (Parakeet, Nemotron)
    // keep the defaults below, which never call the closure — the UI then
    // shows an indeterminate "Transcribing…" instead of a fake percentage.
    func transcribe(
        samples: [Float], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String
    func transcribeDetailed(
        samples: [Float], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DetailedTranscription
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

extension TranscriptionEngine {
    func transcribe(
        samples: [Float], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        try await transcribe(samples: samples)
    }

    func transcribeDetailed(
        samples: [Float], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DetailedTranscription {
        try await transcribeDetailed(samples: samples)
    }
}
