import Foundation
import Testing

@testable import Barktor

// An engine that implements ONLY the base protocol methods — proves the
// progress variants have working default implementations.
private final class MinimalEngine: TranscriptionEngine {
    let supportsStreaming = false
    func warmup() async {}
    func isWarm() async -> Bool { true }
    func transcribe(samples: [Float]) async throws -> String { "base" }
    func transcribeDetailed(samples: [Float]) async throws -> DetailedTranscription {
        DetailedTranscription(text: "base", tokens: [], duration: 1)
    }
    func makeStreamingSession() async throws -> any StreamingSession {
        throw EngineError.streamingNotSupported(engineName: "Minimal")
    }
}

struct EngineProgressTests {
    @Test func defaultProgressVariantsForwardToBaseCalls() async throws {
        let engine: any TranscriptionEngine = MinimalEngine()
        let text = try await engine.transcribe(samples: [0]) { _ in }
        #expect(text == "base")
        let detailed = try await engine.transcribeDetailed(samples: [0]) { _ in }
        #expect(detailed.text == "base")
    }
}
