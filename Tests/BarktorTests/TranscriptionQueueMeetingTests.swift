import Combine
import Foundation
import Testing

@testable import Barktor

@MainActor
struct TranscriptionQueueMeetingTests {
    private func makeWorld() -> (
        queue: TranscriptionQueue, engine: FakeEngine, notifier: SpyNotifier, dir: URL
    ) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-meeting-\(UUID().uuidString)", isDirectory: true)
        let history = HistoryStore(
            directory: base.appendingPathComponent("history", isDirectory: true))
        history.retentionProvider = { .week }
        let queue = TranscriptionQueue(
            directory: base.appendingPathComponent("queue", isDirectory: true),
            history: history)
        let engine = FakeEngine()
        let notifier = SpyNotifier()
        queue.engineResolver = { _, _ in (engine, "Fake") }
        queue.notifier = notifier
        // Documents land in the temp dir, never the real Meetings folder.
        let docsDir = base.appendingPathComponent("meetings", isDirectory: true)
        queue.writeDocument = { output in
            try FileManager.default.createDirectory(
                at: docsDir, withIntermediateDirectories: true)
            let url = docsDir.appendingPathComponent("meeting-\(UUID().uuidString).md")
            try output.markdown.data(using: .utf8)!.write(to: url)
            return url
        }
        queue.salvageDirectory = { docsDir }
        return (queue, engine, notifier, base)
    }

    @Test func micOnlyMeetingWritesDocumentAndNotifies() async throws {
        let (queue, _, notifier, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await queue.enqueueMeeting(
            mic: [Float](repeating: 0.2, count: 16_000 * 3), system: [],
            recordedAt: Date(), engine: .parakeet, whisperModel: "")
        await queue.waitUntilIdle()
        #expect(notifier.meetingDone.count == 1)
        let url = try #require(notifier.meetingDone.first?.revealURL)
        let markdown = try String(contentsOf: url, encoding: .utf8)
        // FakeEngine returns no token timings → format falls back to raw text.
        #expect(markdown.contains("hola mundo"))
        #expect(queue.state == .idle)
    }

    @Test func dualTrackMeetingTranscribesBothAndWeightsProgress() async throws {
        let (queue, engine, notifier, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        engine.progressSteps = [1.0]  // each pass reports "done"
        var fractions: [Double] = []
        let cancellable = queue.$state.sink { state in
            if case .processing(_, _, let fraction?, _) = state { fractions.append(fraction) }
        }
        defer { cancellable.cancel() }
        // System track 3× the mic → remote weight 0.75.
        try await queue.enqueueMeeting(
            mic: [Float](repeating: 0.2, count: 16_000),
            system: [Float](repeating: 0.2, count: 16_000 * 3),
            recordedAt: Date(), engine: .parakeet, whisperModel: "")
        await queue.waitUntilIdle()
        #expect(engine.calls == 2)  // remote pass + local pass
        #expect(notifier.meetingDone.count == 1)
        // Remote pass completion lands at its weight; local completes at 1.0.
        #expect(fractions.contains { abs($0 - 0.75) < 0.01 })
        #expect(fractions.contains { abs($0 - 1.0) < 0.01 })
    }

    @Test func summarySidecarWinsTheRevealURL() async throws {
        let (queue, _, notifier, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sidecar = dir.appendingPathComponent("summary.md")
        queue.summarize = { _ in sidecar }
        try await queue.enqueueMeeting(
            mic: [Float](repeating: 0.2, count: 16_000 * 3), system: [],
            recordedAt: Date(), engine: .parakeet, whisperModel: "")
        await queue.waitUntilIdle()
        #expect(notifier.meetingDone.first?.revealURL == sidecar)
    }

    @Test func failedMeetingSalvagesAudioAndNotifies() async throws {
        let (queue, engine, notifier, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        engine.shouldThrow = true
        try await queue.enqueueMeeting(
            mic: [Float](repeating: 0.2, count: 16_000 * 3),
            system: [Float](repeating: 0.2, count: 16_000 * 3),
            recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
            engine: .parakeet, whisperModel: "")
        await queue.waitUntilIdle()
        #expect(notifier.failures.count == 1)
        let salvaged = try #require(notifier.failures.first?.revealURL)
        #expect(FileManager.default.fileExists(atPath: salvaged.path))
        #expect(salvaged.lastPathComponent.contains("(audio only)"))
        // Both tracks salvaged; the job dir is gone.
        let names = try FileManager.default.contentsOfDirectory(atPath: salvaged.deletingLastPathComponent().path)
        #expect(names.contains { $0.contains("(audio only, system)") })
    }
}
