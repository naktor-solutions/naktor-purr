import Foundation
import os.log

// Persistent dictation history. JSON + WAV files on disk, no database: the
// cap is 1000 entries, decode time is negligible, and file-per-audio keeps
// retention sweeps a plain directory operation. Everything here must fail
// soft - the history is an accessory to dictation, never a gate on it.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [DictationEntry] = []

    let directory: URL
    var audioDirectory: URL { directory.appendingPathComponent("audio", isDirectory: true) }

    // Indirection instead of reading SettingsStore directly so tests can pin
    // a retention without touching the developer's real UserDefaults.
    var retentionProvider: () -> AudioRetention = { .week }

    private let log = Logger(subsystem: "com.arunbrahma.purr", category: "history")
    private var sweepTask: Task<Void, Never>?
    private static let maxEntries = 1000

    // nonisolated: referenced as a default argument value in `init` below,
    // which Swift evaluates in a nonisolated context even though the type
    // is @MainActor. Safe - it only touches thread-safe FileManager APIs.
    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Purr/History", isDirectory: true)
    }

    // Date is stored internally as an offset from the 2001 reference date.
    // Both `.iso8601` (whole-second precision) and `.secondsSince1970`
    // (re-basing to a ~49-years-larger epoch loses low mantissa bits during
    // the addition) fail to round-trip a `Date()` bit-for-bit, which matters
    // here because `DictationEntry`'s `==` is a full-precision struct
    // comparison. Encoding the reference-date offset directly - the same
    // number Foundation stores internally - round-trips exactly.
    private static let dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .custom {
        date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(date.timeIntervalSinceReferenceDate)
    }
    private static let dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        return Date(timeIntervalSinceReferenceDate: try container.decode(Double.self))
    }

    init(directory: URL = HistoryStore.defaultDirectory) {
        self.directory = directory
        self.entries = Self.load(from: directory)
    }

    // ------------------------------------------------------------------
    // CRUD
    // ------------------------------------------------------------------

    func add(_ entry: DictationEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            for evicted in entries[Self.maxEntries...] {
                removeAudioFile(of: evicted)
            }
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
    }

    func update(_ id: UUID, mutate: (inout DictationEntry) -> Void) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        mutate(&entries[idx])
        save()
    }

    func delete(_ id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        removeAudioFile(of: entries[idx])
        entries.remove(at: idx)
        save()
    }

    func deleteAll() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: audioDirectory)
        save()
    }

    func audioURL(for entry: DictationEntry) -> URL? {
        guard let name = entry.audioFilename else { return nil }
        let url = audioDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // ------------------------------------------------------------------
    // Audio persistence (off the dictation hot path)
    // ------------------------------------------------------------------

    // Writes <id>.wav in a detached task so transcription never waits on
    // disk I/O, then records the filename on the entry. A write failure
    // degrades that entry to text-only - dictation itself is unaffected.
    // Returns the task so tests can await completion; callers may ignore it.
    @discardableResult
    func persistAudio(id: UUID, samples: [Float]) -> Task<Void, Never> {
        guard retentionProvider().maxAge != nil else { return Task {} }
        let dir = audioDirectory
        let filename = "\(id.uuidString).wav"
        return Task.detached(priority: .utility) { [weak self] in
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try WAVFile.write(samples: samples, to: dir.appendingPathComponent(filename))
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if self.entries.contains(where: { $0.id == id }) {
                        self.update(id) { $0.audioFilename = filename }
                    } else {
                        // Entry vanished (deleted or FIFO-evicted) while the
                        // write was in flight - remove the orphan, nothing
                        // will ever reference it and the retention sweep only
                        // visits files that known entries point at.
                        try? FileManager.default.removeItem(at: dir.appendingPathComponent(filename))
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.log.warning(
                        "History audio write failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public) - entry kept text-only"
                    )
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Retention
    // ------------------------------------------------------------------

    func sweepExpiredAudio(now: Date = Date()) {
        let retention = retentionProvider()
        var changed = false
        for idx in entries.indices where entries[idx].audioFilename != nil {
            let expired: Bool
            if let maxAge = retention.maxAge {
                expired = now.timeIntervalSince(entries[idx].date) > maxAge
            } else {
                expired = true  // retention "Never": keep no audio at all
            }
            guard expired else { continue }
            removeAudioFile(of: entries[idx])
            entries[idx].audioFilename = nil
            changed = true
        }
        if changed { save() }
    }

    func startDailySweeps() {
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sweepExpiredAudio()
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    // ------------------------------------------------------------------
    // Stats
    // ------------------------------------------------------------------

    func stats(now: Date = Date()) -> HistoryStats {
        var totalWords = 0
        var spokenSeconds: TimeInterval = 0
        var days = Set<DateComponents>()
        let calendar = Calendar.current
        for entry in entries {
            days.insert(calendar.dateComponents([.year, .month, .day], from: entry.date))
            guard let text = entry.displayText, !text.isEmpty else { continue }
            totalWords += text.split(whereSeparator: \.isWhitespace).count
            spokenSeconds += entry.duration
        }
        var streak = 0
        var cursor = now
        while days.contains(calendar.dateComponents([.year, .month, .day], from: cursor)) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        let wpm = spokenSeconds > 0 ? Double(totalWords) / (spokenSeconds / 60.0) : 0
        return HistoryStats(totalWords: totalWords, averageWPM: wpm, streakDays: streak)
    }

    // ------------------------------------------------------------------
    // Disk
    // ------------------------------------------------------------------

    private static func load(from directory: URL) -> [DictationEntry] {
        let url = directory.appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = Self.dateDecodingStrategy
        if let entries = try? decoder.decode([DictationEntry].self, from: data) {
            return entries
        }
        // Corrupt file: move it aside and start empty rather than blocking
        // dictation behind an unreadable history.
        let bak = directory.appendingPathComponent("history.json.bak")
        try? FileManager.default.removeItem(at: bak)
        try? FileManager.default.moveItem(at: url, to: bak)
        Logger(subsystem: "com.arunbrahma.purr", category: "history")
            .error("history.json was corrupt - moved to history.json.bak, starting empty")
        return []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = Self.dateEncodingStrategy
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: directory.appendingPathComponent("history.json"), options: .atomic)
        } catch {
            log.error("History save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeAudioFile(of entry: DictationEntry) {
        guard let name = entry.audioFilename else { return }
        try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(name))
    }
}
