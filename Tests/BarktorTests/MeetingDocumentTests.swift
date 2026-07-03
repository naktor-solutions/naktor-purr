import FluidAudio
import Foundation
import Testing

@testable import Barktor

struct MeetingDocumentTests {
    private func token(_ text: String, _ start: Double, _ end: Double)
        -> DetailedTranscription.TimedToken
    {
        .init(text: text, start: start, end: end)
    }

    @Test func testLocalOnlyLabelsEverythingYouAndShowsEngine() {
        let asr = DetailedTranscription(
            text: "hola mundo",
            tokens: [token("hola", 0, 0.5), token(" mundo", 0.6, 1.0)],
            duration: 2)
        let out = MeetingDocument.format(
            localOnly: asr, duration: 2, recordedAt: Date(timeIntervalSince1970: 0),
            engineLabel: "Whisper (large-v3)")
        #expect(out.markdown.contains("**You:** hola mundo"))
        #expect(out.markdown.contains("_Engine: Whisper (large-v3)_"))
        #expect(!(out.markdown.contains("Parakeet TDT v2")))
    }

    @Test func testEmptyTokensFallBackToRawText() {
        let asr = DetailedTranscription(text: "sin timings", tokens: [], duration: 2)
        let out = MeetingDocument.format(
            localOnly: asr, duration: 2, recordedAt: Date(timeIntervalSince1970: 0),
            engineLabel: "Whisper (tiny)")
        #expect(out.markdown.contains("sin timings"))
        #expect(!(out.markdown.contains("**You:**")))
    }

    @Test func testDualTrackAttributesRemoteSpeakers() {
        let local = DetailedTranscription(
            text: "vale", tokens: [token("vale", 2.0, 2.4)], duration: 5)
        let remote = DetailedTranscription(
            text: "buenos dias", tokens: [token("buenos", 0, 0.4), token(" dias", 0.5, 0.9)],
            duration: 5)
        let segments = [
            TimedSpeakerSegment(
                speakerId: "speaker_0001", embedding: [], startTimeSeconds: 0.0,
                endTimeSeconds: 1.0, qualityScore: 1.0)
        ]
        let out = MeetingDocument.format(
            localASR: local, remoteASR: remote, remoteSegments: segments,
            duration: 5, recordedAt: Date(timeIntervalSince1970: 0),
            engineLabel: "Whisper (large-v3)")
        #expect(out.markdown.contains("**Speaker 1:** buenos dias"))
        #expect(out.markdown.contains("**You:** vale"))
        #expect(out.markdown.contains("_Engine: Whisper (large-v3) + FluidAudio Diarizer_"))
    }

    @Test func testDualTrackKeepsLocalTextWhenLocalTokensAreEmpty() {
        // Whisper models without an alignment head can return text with zero
        // word timings. The local (mic) side must not be silently dropped
        // just because the remote side happened to produce real timings.
        let local = DetailedTranscription(text: "vale", tokens: [], duration: 5)
        let remote = DetailedTranscription(
            text: "buenos dias", tokens: [token("buenos", 0, 0.4), token(" dias", 0.5, 0.9)],
            duration: 5)
        let segments = [
            TimedSpeakerSegment(
                speakerId: "speaker_0001", embedding: [], startTimeSeconds: 0.0,
                endTimeSeconds: 1.0, qualityScore: 1.0)
        ]
        let out = MeetingDocument.format(
            localASR: local, remoteASR: remote, remoteSegments: segments,
            duration: 5, recordedAt: Date(timeIntervalSince1970: 0),
            engineLabel: "Whisper (large-v3)")
        #expect(out.markdown.contains("**You:** vale"))
        #expect(out.markdown.contains("**Speaker 1:** buenos dias"))
    }
}
