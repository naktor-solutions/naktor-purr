import FluidAudio
import Foundation

// Engine-agnostic batch transcription result with per-token timings.
// Meeting mode uses `tokens` to align text with diarized speaker segments;
// an engine that can't produce timings returns an empty array and the
// meeting transcript falls back to unattributed text instead of failing.
struct DetailedTranscription {
    struct TimedToken: Equatable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    let text: String
    let tokens: [TimedToken]
    let duration: TimeInterval
}

extension DetailedTranscription {
    // FluidAudio's ASRResult (Parakeet) mapped to the engine-agnostic shape.
    init(asrResult: ASRResult) {
        self.init(
            text: asrResult.text,
            tokens: (asrResult.tokenTimings ?? []).map {
                TimedToken(text: $0.token, start: $0.startTime, end: $0.endTime)
            },
            duration: asrResult.duration
        )
    }
}
