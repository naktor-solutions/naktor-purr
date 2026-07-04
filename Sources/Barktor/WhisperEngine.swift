import Foundation
import WhisperKit
import os.log

// Wraps WhisperKit. Multilingual fallback for the long tail of languages
// (Asian, Arabic, etc.) that the English-only Parakeet v2 doesn't cover.
//
// Streaming is intentionally not implemented: WhisperKit's chunked
// streaming runs on whole-30s windows and produces awkward partial
// revisions. makeStreamingSession() throws so callers fall back to batch.
@MainActor
final class WhisperEngine: TranscriptionEngine {
    nonisolated let supportsStreaming: Bool = false
    nonisolated let modelIdentifier: String

    private var pipe: WhisperKit?
    private var loadedModel: String?
    // The single in-flight warmup. Loading a Whisper model runs the CoreML
    // Apple-Neural-Engine specialization (`prewarm`), a multi-minute one-time
    // compile for large-v3. reloadEngine() fires a background warmup the moment
    // the user switches to Whisper; without coalescing, the first dictation's
    // transcribe() starts a SECOND prewarm+load while that one is still running,
    // and two concurrent large-v3 ANE compiles thrash the single compiler into a
    // ~20-minute stall. Both callers await this one task instead. Mirrors
    // ParakeetEngine.batchLoadTask.
    private var warmupTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.naktor.barktor", category: "whisper")

    init(modelName: String) {
        self.modelIdentifier = modelName
    }

    // Pre-load the model so the first dictation doesn't pay the disk-load and
    // ANE-compile cost. Safe to call multiple times - same-model warmups are
    // no-ops, and concurrent calls coalesce onto one load (see warmupTask).
    // If the weights aren't on disk, this fails-soft (logs and returns)
    // rather than triggering a background download - the Settings UI is
    // the only path that pulls models, so it can show progress and surface
    // failures inline.
    func warmup() async {
        if loadedModel == modelIdentifier, pipe != nil { return }
        if let inFlight = warmupTask {
            await inFlight.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadPipe()
        }
        warmupTask = task
        defer { if warmupTask == task { warmupTask = nil } }
        await task.value
    }

    func isWarm() async -> Bool { loadedModel == modelIdentifier && pipe != nil }

    private func loadPipe() async {
        do {
            let folder = try await ModelManager.localFolder(for: modelIdentifier)
            let cfg = WhisperKitConfig(
                modelFolder: folder.path,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false
            )
            let pipe = try await WhisperKit(cfg)
            self.pipe = pipe
            self.loadedModel = modelIdentifier
            log.info("Whisper warmed up - model \(self.modelIdentifier, privacy: .public)")
        } catch {
            log.error(
                "Warmup failed for \(self.modelIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func transcribe(samples: [Float]) async throws -> String {
        if loadedModel != modelIdentifier { await warmup() }
        guard let pipe = pipe else { throw EngineError.notLoaded }

        // Translate (X→English) only when the user opted in AND the loaded
        // model can actually do it. Turbo and English-only builds silently
        // ignore the translate task and return the source language, so we
        // never request it from them.
        let translate =
            SettingsStore.shared.translateToEnglish
            && ModelManager.supportsTranslation(modelIdentifier)
        // The shared dictation language (ISO code, "" = auto-detect) pins both
        // the transcription language and the translate source, so a short clip
        // isn't misdetected. Empty = Whisper auto-detects.
        let pinned = SettingsStore.shared.dictationLanguage
        let language: String? = pinned.isEmpty ? nil : pinned
        let options = DecodingOptions(
            verbose: false,
            task: translate ? .translate : .transcribe,
            language: language,
            temperature: 0.0,
            sampleLength: 224,
            usePrefillPrompt: true,
            withoutTimestamps: true,
            wordTimestamps: false
        )
        let started = Date()
        let results: [TranscriptionResult] = try await pipe.transcribe(
            audioArray: samples,
            decodeOptions: options
        )
        let elapsed = Date().timeIntervalSince(started)
        let raw = results.map(\.text).joined(separator: " ")
        let cleaned = TranscriptCleaner.clean(raw)
        log.info(
            "Transcribed \(samples.count, privacy: .public) samples in \(String(format: "%.2f", elapsed), privacy: .public)s (task=\(translate ? "translate" : "transcribe", privacy: .public), lang=\(language ?? "auto", privacy: .public))"
        )
        return cleaned
    }

    func makeStreamingSession() async throws -> any StreamingSession {
        throw EngineError.streamingNotSupported(engineName: "Whisper")
    }

    // WhisperKit's DTW word timings mapped to the engine-agnostic shape.
    // MeetingDocument concatenates token text verbatim, so every word must
    // carry its leading space (WhisperKit usually includes it; normalize
    // the ones that don't so words never run together).
    nonisolated static func timedTokens(from words: [WordTiming]) -> [DetailedTranscription.TimedToken] {
        words.map { timing in
            let text = timing.word.hasPrefix(" ") ? timing.word : " " + timing.word
            return DetailedTranscription.TimedToken(
                text: text,
                start: TimeInterval(timing.start),
                end: TimeInterval(timing.end)
            )
        }
    }

    // Detailed variant for meeting mode. Always the plain transcribe task
    // with auto-detected language: the translate-to-English toggle is a
    // dictation-only affordance, and a Spanish meeting must stay Spanish.
    func transcribeDetailed(samples: [Float]) async throws -> DetailedTranscription {
        if loadedModel != modelIdentifier { await warmup() }
        guard let pipe = pipe else { throw EngineError.notLoaded }
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: nil,
            temperature: 0.0,
            sampleLength: 224,
            usePrefillPrompt: true,
            withoutTimestamps: false,
            wordTimestamps: true
        )
        let started = Date()
        let results: [TranscriptionResult] = try await pipe.transcribe(
            audioArray: samples,
            decodeOptions: options
        )
        let elapsed = Date().timeIntervalSince(started)
        let words = results.flatMap(\.segments).flatMap { $0.words ?? [] }
        let text = TranscriptCleaner.clean(results.map(\.text).joined(separator: " "))
        log.info(
            "Whisper detailed transcribe: \(samples.count, privacy: .public) samples in \(String(format: "%.2f", elapsed), privacy: .public)s, \(words.count, privacy: .public) word timings"
        )
        return DetailedTranscription(
            text: text,
            tokens: Self.timedTokens(from: words),
            duration: TimeInterval(samples.count) / 16_000.0
        )
    }

    // Real batch progress. WhisperKit tracks each transcribe call on
    // pipe.progress: runTranscribeTask adds one child Progress per call whose
    // units are SECONDS of audio seeked, and resets the parent when a call
    // finishes. Polling fractionCompleted is simpler and safer than the
    // per-token TranscriptionCallback (which fires off-actor) for the same
    // fidelity a progress bar needs. Verified against WhisperKit's
    // TranscribeTask.swift (progress.totalUnitCount = totalSeekDuration).
    private func pollingProgress<T>(
        progress: @escaping @Sendable (Double) -> Void,
        during operation: () async throws -> T
    ) async rethrows -> T {
        let poller = Task { [weak self] in
            while !Task.isCancelled {
                if let fraction = await self?.pipe?.progress.fractionCompleted, fraction > 0 {
                    progress(min(1, fraction))
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { poller.cancel() }
        return try await operation()
    }

    func transcribe(
        samples: [Float], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        try await pollingProgress(progress: progress) {
            try await transcribe(samples: samples)
        }
    }

    func transcribeDetailed(
        samples: [Float], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DetailedTranscription {
        try await pollingProgress(progress: progress) {
            try await transcribeDetailed(samples: samples)
        }
    }
}

enum EngineError: LocalizedError {
    case notLoaded
    case streamingNotSupported(engineName: String)
    case modelDirectoryMissing

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "Speech model is not loaded. Open Settings → Engine and download one."
        case .streamingNotSupported(let name):
            return
                "\(name) does not support real-time streaming. Switch the engine, or turn off Smart typing."
        case .modelDirectoryMissing:
            return "Model files are missing on disk. Open Settings → Engine to download."
        }
    }
}

// Both engines emit the same junk that Whisper learned from YouTube
// captioning: "[Music]", "(silence)", "<|endoftext|>", and so on. Cleaning
// them is identical work - share the implementation so post-process
// results match exactly across engines.
enum TranscriptCleaner {
    static func clean(_ text: String) -> String {
        var result = text
        let patterns = [
            #"\[[^\]]+\]"#,
            #"\([^)]*?(?:music|silence|noise|laugh|applause|inaudible)[^)]*?\)"#,
            #"<\|[^|]+\|>"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        result = result.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
