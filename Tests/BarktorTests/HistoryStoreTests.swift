import Foundation
import Testing

@testable import Barktor

@MainActor
struct HistoryStoreTests {
    private func makeStore() -> (HistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("barktor-history-\(UUID().uuidString)", isDirectory: true)
        return (HistoryStore(directory: dir), dir)
    }

    private func entry(
        id: UUID = UUID(), date: Date = Date(), text: String? = "hola",
        status: DictationEntry.Status = .ok, audio: String? = nil
    ) -> DictationEntry {
        DictationEntry(
            id: id, date: date, duration: 2.0, rawText: text, processedText: text,
            engineUsed: "parakeet", mode: .batch, status: status, errorMessage: nil,
            audioFilename: audio)
    }

    @Test func addPersistsAndReloads() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = entry()
        store.add(e)
        let reloaded = HistoryStore(directory: dir)
        #expect(reloaded.entries == [e])
    }

    @Test func newestFirstAndFIFOCap() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<1005 {
            store.add(entry(date: Date(timeIntervalSince1970: Double(i))))
        }
        #expect(store.entries.count == 1000)
        // Newest (latest timestamp) stays at the front; the 5 oldest were evicted.
        #expect(store.entries.first?.date == Date(timeIntervalSince1970: 1004))
        #expect(store.entries.last?.date == Date(timeIntervalSince1970: 5))
    }

    @Test func corruptJSONMovesToBakAndStartsEmpty() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.add(entry())
        try Data("not json{{".utf8).write(to: dir.appendingPathComponent("history.json"))
        let reloaded = HistoryStore(directory: dir)
        #expect(reloaded.entries.isEmpty)
        #expect(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.json.bak").path))
    }

    @Test func sweepDeletesExpiredAudioAndClearsFilename() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.retentionProvider = { .day }
        let old = entry(date: Date(timeIntervalSinceNow: -48 * 3600), audio: "old.wav")
        let fresh = entry(date: Date(), audio: "fresh.wav")
        try FileManager.default.createDirectory(at: store.audioDirectory, withIntermediateDirectories: true)
        try WAVFile.write(samples: [0, 0.5], to: store.audioDirectory.appendingPathComponent("old.wav"))
        try WAVFile.write(samples: [0, 0.5], to: store.audioDirectory.appendingPathComponent("fresh.wav"))
        store.add(old)
        store.add(fresh)
        store.sweepExpiredAudio()
        #expect(store.entries.first(where: { $0.id == old.id })?.audioFilename == nil)
        #expect(store.entries.first(where: { $0.id == fresh.id })?.audioFilename == "fresh.wav")
        #expect(!FileManager.default.fileExists(atPath: store.audioDirectory.appendingPathComponent("old.wav").path))
    }

    @Test func statsCountWordsAndStreak() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        store.add(entry(date: now.addingTimeInterval(-24 * 3600), text: "buenos dias equipo"))
        store.add(entry(date: now, text: "hola mundo"))
        let stats = store.stats(now: now)
        #expect(stats.totalWords == 5)
        #expect(stats.streakDays == 2)
        // 5 words over 4s of audio = 75 WPM.
        #expect(abs(stats.averageWPM - 75.0) < 0.01)
    }

    @Test func deleteRemovesAudioFile() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = entry(audio: "gone.wav")
        try FileManager.default.createDirectory(at: store.audioDirectory, withIntermediateDirectories: true)
        try WAVFile.write(samples: [0, 0.1], to: store.audioDirectory.appendingPathComponent("gone.wav"))
        store.add(e)
        store.delete(e.id)
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.audioDirectory.appendingPathComponent("gone.wav").path))
    }

    @Test func evictionDeletesAudioFile() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = entry(date: Date(timeIntervalSince1970: 0), audio: "a.wav")
        try FileManager.default.createDirectory(at: store.audioDirectory, withIntermediateDirectories: true)
        try WAVFile.write(samples: [0, 0.5], to: store.audioDirectory.appendingPathComponent("a.wav"))
        store.add(a)
        for i in 1...1000 {
            store.add(entry(date: Date(timeIntervalSince1970: Double(i))))
        }
        #expect(!store.entries.contains(where: { $0.id == a.id }))
        #expect(!FileManager.default.fileExists(atPath: store.audioDirectory.appendingPathComponent("a.wav").path))
    }

    @Test func beginRetryGatesToOneAtATime() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = UUID()
        let b = UUID()
        #expect(store.beginRetry(a) == true)
        #expect(store.beginRetry(b) == false)
        #expect(store.beginRetry(a) == false)
        store.endRetry(a)
        #expect(store.beginRetry(b) == true)
    }

    @Test func persistAudioCleansUpWhenEntryVanishesMidWrite() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = entry()
        store.add(e)
        let task = store.persistAudio(id: e.id, samples: [Float](repeating: 0.25, count: 400))
        store.delete(e.id)
        await task.value
        #expect(store.entries.isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: store.audioDirectory.appendingPathComponent("\(e.id.uuidString).wav").path))
    }
}
