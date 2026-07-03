import FluidAudio
import Testing

@testable import Barktor

struct DetailedTranscriptionTests {
    @Test func testMapsParakeetTokenTimings() {
        let asr = ASRResult(
            text: "hola mundo", confidence: 0.9, duration: 2.0, processingTime: 0.1,
            tokenTimings: [
                TokenTiming(token: "hola", tokenId: 1, startTime: 0.0, endTime: 0.5, confidence: 0.9),
                TokenTiming(token: " mundo", tokenId: 2, startTime: 0.6, endTime: 1.1, confidence: 0.9),
            ])
        let detailed = DetailedTranscription(asrResult: asr)
        #expect(detailed.text == "hola mundo")
        #expect(
            detailed.tokens
                == [
                    DetailedTranscription.TimedToken(text: "hola", start: 0.0, end: 0.5),
                    DetailedTranscription.TimedToken(text: " mundo", start: 0.6, end: 1.1),
                ])
        #expect(detailed.duration == 2.0)
    }

    @Test func testNilTimingsBecomeEmptyTokens() {
        let asr = ASRResult(text: "x", confidence: 1, duration: 1, processingTime: 0)
        #expect(DetailedTranscription(asrResult: asr).tokens.isEmpty)
    }
}
