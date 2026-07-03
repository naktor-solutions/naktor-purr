import Foundation
import Testing
import WhisperKit

@testable import Barktor

struct WhisperTimedTokenTests {
    @Test func testWordsKeepTheirTimings() {
        let words = [
            WordTiming(word: " hola", tokens: [1], start: 0.0, end: 0.4, probability: 1),
            WordTiming(word: " mundo", tokens: [2], start: 0.5, end: 0.9, probability: 1),
        ]
        // end times compare against TimeInterval(Float(_)), not a bare Double
        // literal: widening Float 0.4/0.9 to Double doesn't land on the same
        // bit pattern as typing 0.4/0.9 as a Double literal, so a literal
        // comparison would fail regardless of the mapper's correctness.
        #expect(
            WhisperEngine.timedTokens(from: words)
                == [
                    DetailedTranscription.TimedToken(
                        text: " hola", start: 0.0, end: TimeInterval(Float(0.4))),
                    DetailedTranscription.TimedToken(
                        text: " mundo", start: 0.5, end: TimeInterval(Float(0.9))),
                ])
    }

    @Test func testMissingLeadingSpaceIsAdded() {
        // MeetingDocument concatenates tokens verbatim (Parakeet BPE tokens
        // carry their own leading spaces), so Whisper words must too.
        let words = [WordTiming(word: "hola", tokens: [1], start: 0, end: 1, probability: 1)]
        #expect(WhisperEngine.timedTokens(from: words).first?.text == " hola")
    }
}
