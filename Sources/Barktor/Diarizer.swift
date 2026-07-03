import FluidAudio
import Foundation
import os.log

// Speaker diarization for meeting mode. Wraps FluidAudio's
// `OfflineDiarizerManager` (community-1, 17.7% DER on AMI) which is the
// batch/quality variant - better than the streaming diarizer we'd use for
// live attribution. Meetings are saved-once-then-processed, so batch is the
// right pick.
//
// Models pull from `FluidInference/speaker-diarization-coreml` on first
// use, into FluidAudio's default Application Support cache. We piggyback
// on that path rather than reroute it because the FluidAudio SDK already
// handles version pinning, redownload-on-corruption, and ANE compilation.
@MainActor
final class Diarizer {
    private var manager: OfflineDiarizerManager?
    private let log = Logger(subsystem: "com.naktor.barktor", category: "diarizer")

    func warmup() async {
        if manager != nil { return }
        do {
            try await downloadAndWarmup()
        } catch {
            log.error("Diarizer warmup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // Same work as warmup() but propagates errors instead of logging-and-swallowing them.
    func downloadAndWarmup() async throws {
        if manager != nil { return }
        let m = OfflineDiarizerManager(config: .default)
        try await m.prepareModels(directory: ModelManager.modelsDirectory)
        self.manager = m
        log.info("Offline diarizer downloaded and warmed up.")
    }

    func diarize(samples: [Float]) async throws -> [TimedSpeakerSegment] {
        if manager == nil { await warmup() }
        guard let manager else { throw DiarizerError.notInitialized }
        let started = Date()
        let result = try await manager.process(audio: samples)
        let elapsed = Date().timeIntervalSince(started)
        log.info(
            "Diarized \(samples.count, privacy: .public) samples → \(result.segments.count, privacy: .public) segments in \(String(format: "%.2f", elapsed), privacy: .public)s"
        )
        return result.segments
    }

    // Drops the in-memory CoreML graphs so a subsequent on-disk
    // delete() doesn't leave a stale mmap pointing at removed files.
    // MUST run before removeItem.
    func unload() {
        manager = nil
        log.info("Offline diarizer unloaded.")
    }

    // FluidAudio writes the diarizer's CoreML graphs and config JSONs into this
    // folder. Routed under Barktor's own models folder (not FluidAudio's default)
    // so every Barktor model lives in one place that uninstalling removes.
    static var modelDirectory: URL {
        ModelManager.modelsDirectory.appendingPathComponent("speaker-diarization", isDirectory: true)
    }

    static func isInstalled() -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: modelDirectory.path)
        else { return false }
        return !contents.isEmpty
    }

    static func delete() throws {
        let url = modelDirectory
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
