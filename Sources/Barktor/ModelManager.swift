import Foundation
import WhisperKit
import os.log

// Owns model files on disk. WhisperKit can download to its own cache, but we
// route everything through ~/Library/Application Support/Barktor/models so:
//   - the user can find and delete models without spelunking ~/Library/Caches
//   - the location survives `defaults delete` and Xcode-cache cleaning
//   - a future "import model from file" flow has a documented home for them.
enum ModelManager {
    private static let log = Logger(subsystem: "com.naktor.barktor", category: "models")

    // Whisper Large V3 Turbo: 4 decoder layers (vs 32 in Large V3),
    // ~6× decode speed. The `_632MB` suffix selects argmax's quantised
    // CoreML build - fits in memory and runs on the ANE on every supported
    // Mac. The un-suffixed variant on the same repo is full-precision and
    // ~1.5 GB on disk; we deliberately do not surface it.
    static let defaultModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let modelRepo = "argmaxinc/whisperkit-coreml"

    // Curated list shown in Settings. WhisperKit's repo has dozens of
    // variants; surfacing all of them is overwhelming. These are the ones
    // worth picking between for dictation.
    //
    // sizeMB values match the total bytes downloaded from
    // argmaxinc/whisperkit-coreml for each variant (sum of all files in
    // the variant directory, including .mlmodelc weights and, where the
    // repo also ships .mlpackage duplicates, those too). Keep in sync with
    // the repo on Hugging Face.
    //
    // `supportsTranslation` is the single capability flag the rest of the
    // app reads. English-only (.en) builds and Turbo both fail it - they
    // can't translate to English. Only Base, Small, and Large V3 are true.
    // Notes lead with "Multilingual." or "English only." - except Turbo,
    // where that prefix misleads (users assume translation works), so its
    // note instead emphasises the real strength: quality at real-time speed.
    static let curatedModels: [ModelChoice] = [
        ModelChoice(
            id: "openai_whisper-tiny.en",
            label: "Tiny EN - lowest latency",
            sizeMB: 146,
            note: "English only. Smallest and fastest; lowest accuracy. For short commands.",
            supportsTranslation: false
        ),
        ModelChoice(
            id: "openai_whisper-base.en",
            label: "Base EN - low latency",
            sizeMB: 140,
            note: "English only. Small, low latency; better accuracy than Tiny.",
            supportsTranslation: false
        ),
        ModelChoice(
            id: "openai_whisper-base",
            label: "Base",
            sizeMB: 140,
            note: "Multilingual. Smallest, fastest multilingual; low accuracy.",
            supportsTranslation: true
        ),
        ModelChoice(
            id: "openai_whisper-small",
            label: "Small",
            sizeMB: 464,
            note: "Multilingual. Balanced accuracy and latency for everyday use.",
            supportsTranslation: true
        ),
        ModelChoice(
            id: "openai_whisper-large-v3_947MB",
            label: "Large V3",
            sizeMB: 948,
            note: "Multilingual. Highest accuracy with translation; slower than Turbo.",
            supportsTranslation: true
        ),
        ModelChoice(
            id: "openai_whisper-large-v3-v20240930_turbo_632MB",
            label: "Large V3 Turbo (recommended)",
            sizeMB: 616,
            note: "Best quality at real-time speed on Apple Silicon.",
            supportsTranslation: false
        ),
    ]

    // Whether the Translate-to-English task is meaningful for this model.
    // Unknown / uncurated names default to false so the engine never asks
    // a model to do something it can't.
    static func supportsTranslation(_ modelName: String) -> Bool {
        curatedModels.first { $0.id == modelName }?.supportsTranslation ?? false
    }

    // Compact model name for tight UI like history rows: the curated label
    // without its picker-only suffixes ("Large V3 Turbo (recommended)" ->
    // "Large V3 Turbo", "Tiny EN - lowest latency" -> "Tiny EN"). Ids no
    // longer in the curated list fall back to the raw id minus the vendor
    // prefix, so old history entries stay readable.
    static func shortLabel(forModel id: String) -> String {
        guard let label = curatedModels.first(where: { $0.id == id })?.label else {
            let prefix = "openai_whisper-"
            return id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
        }
        let base = label.components(separatedBy: " - ").first ?? label
        return base.replacingOccurrences(of: " (recommended)", with: "")
    }

    static var modelsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0]
        let dir = support.appendingPathComponent("Barktor/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func localFolder(for modelName: String) async throws -> URL {
        let local = modelsDirectory.appendingPathComponent(modelName, isDirectory: true)
        if FileManager.default.fileExists(atPath: local.path),
            let contents = try? FileManager.default.contentsOfDirectory(atPath: local.path),
            !contents.isEmpty
        {
            return local
        }
        // Files missing. We deliberately don't auto-pull here - the warmup
        // path would race with the Settings UI's explicit download (both
        // converge on `download` and clobber each other on `copyItem`),
        // and a silent ~450 MB background fetch with no progress UI is
        // worse UX than a clear "open Settings → Engine to install".
        // EngineError.modelDirectoryMissing surfaces the latter on the next transcribe.
        throw EngineError.modelDirectoryMissing
    }

    static func isInstalled(_ modelName: String) -> Bool {
        let local = modelsDirectory.appendingPathComponent(modelName, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: local.path) else {
            return false
        }
        return !contents.isEmpty
    }

    @discardableResult
    static func download(modelName: String, progress: @escaping (Double) -> Void) async throws -> URL {
        log.info("Downloading model \(modelName, privacy: .public) from \(modelRepo, privacy: .public)")
        // WhisperKit caches under its own root; we copy/symlink the result
        // into our Application Support tree so it lives where the rest of
        // the app expects it.
        let cached = try await WhisperKit.download(
            variant: modelName,
            from: modelRepo
        ) { p in
            progress(p.fractionCompleted)
        }
        let dest = modelsDirectory.appendingPathComponent(modelName, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: cached, to: dest)
        log.info("Model \(modelName, privacy: .public) installed at \(dest.path, privacy: .public)")
        return dest
    }

    static func delete(_ modelName: String) throws {
        let local = modelsDirectory.appendingPathComponent(modelName, isDirectory: true)
        if FileManager.default.fileExists(atPath: local.path) {
            try FileManager.default.removeItem(at: local)
        }
    }

    // Removes every downloaded model in one sweep: Whisper checkpoints, the
    // Gemma GGUF, and the FluidAudio CoreML bundles (Parakeet batch + EOU and
    // the diarizer) - all of which now live under this one folder. Meeting
    // transcripts live in a sibling folder and are deliberately left alone.
    // Callers MUST release any in-memory model sessions first so a deleted
    // file isn't left mmap'd behind a live handle.
    static func deleteAllModels() throws {
        let dir = modelsDirectory
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}

struct ModelChoice: Identifiable, Hashable {
    let id: String
    let label: String
    let sizeMB: Int
    let note: String
    // True only for checkpoints that can actually run Whisper's X->English
    // translate task. English-only (.en) builds can't read non-English at
    // all; Turbo (large-v3-turbo) is multilingual for transcription but was
    // fine-tuned without translation data. Both end up false here. Only
    // Base, Small, and Large V3 are true. Gates the Translate toggle's
    // enabled state in Settings AND WhisperEngine's runtime task choice.
    let supportsTranslation: Bool
}
