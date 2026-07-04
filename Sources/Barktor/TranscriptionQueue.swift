import FluidAudio
import Foundation
import os.log

enum QueueError: LocalizedError {
    case audioMissing

    var errorDescription: String? {
        switch self {
        case .audioMissing:
            return "The saved audio for this entry is no longer available."
        }
    }
}

// Serial background transcription queue — the single place ALL batch ASR
// runs (meeting processing, dropped files, history retries). Jobs persist to
// disk (job.json + WAVs) before processing, so a crash or quit never loses
// audio; scanAndResume() at startup re-enqueues whatever was pending. One
// job transcribes at a time: two concurrent Whisper pipes would double model
// memory for no wall-clock win.
//
// Everything external is injected (engine resolution, post-processing,
// diarization, summarization, document writing, notifications) so tests run
// the full job lifecycle against fakes over temp directories.
@MainActor
final class TranscriptionQueue: ObservableObject {
    static let shared = TranscriptionQueue()

    enum QueueState: Equatable {
        case idle
        // fraction nil = indeterminate (Parakeet/Nemotron report no signal).
        case processing(label: String, stage: String, fraction: Double?, queued: Int)
    }

    @Published private(set) var state: QueueState = .idle
    // Entry IDs of file jobs waiting or transcribing — HistoryView rows show
    // their spinner from this.
    @Published private(set) var activeEntryIDs: Set<UUID> = []

    // ------------------------------------------------------------------
    // Injected dependencies. Defaults work standalone; AppCoordinator.start()
    // overrides them with the app's shared engines and real pipelines.
    // ------------------------------------------------------------------

    // MUST return instances safe against the live dictation engine: fresh
    // WhisperEngine per job (WhisperKit doesn't serialize concurrent calls),
    // shared actor-based Parakeet/Nemotron.
    var engineResolver:
        (SettingsStore.Engine, String) -> (engine: any TranscriptionEngine, label: String) = {
            choice, model in
            switch choice {
            case .parakeet: return (ParakeetEngine(), "Parakeet TDT v2")
            case .parakeetV3: return (ParakeetEngine(version: .v3), "Parakeet TDT v3")
            case .nemotron: return (NemotronStreamingEngine(), "Multilingual (Nemotron)")
            case .whisper: return (WhisperEngine(modelName: model), "Whisper (\(model))")
            }
        }
    // Deterministic pass + optional LLM polish for file jobs; the duration
    // parameter lets the wiring skip polish on long audio (spec: ≤ 5 min).
    var postProcess: (String, TimeInterval) async -> String = { raw, _ in raw }
    var diarize: ([Float]) async throws -> [TimedSpeakerSegment] = { _ in [] }
    // Returns the summary sidecar URL, or nil when skipped or failed.
    var summarize: (URL) async -> URL? = { _ in nil }
    var writeDocument: (MeetingDocument.Output) throws -> URL = { try MeetingDocument.write($0) }
    var salvageDirectory: () -> URL = { MeetingDocument.meetingsDirectory() }
    var notifier: any Notifying = NullNotifier()

    let directory: URL
    private let history: HistoryStore
    private var jobs: [TranscriptionJob] = []
    private var worker: Task<Void, Never>?
    private let log = Logger(subsystem: "com.naktor.barktor", category: "queue")

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Barktor/Queue", isDirectory: true)
    }

    init(directory: URL = TranscriptionQueue.defaultDirectory, history: HistoryStore? = nil) {
        self.directory = directory
        self.history = history ?? HistoryStore.shared
    }

    // ------------------------------------------------------------------
    // Disk layout
    // ------------------------------------------------------------------

    func jobDirectory(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func persist(_ job: TranscriptionJob) throws {
        try FileManager.default.createDirectory(
            at: jobDirectory(job.id), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(job)
        try data.write(
            to: jobDirectory(job.id).appendingPathComponent("job.json"), options: .atomic)
    }

    private func removeJobDir(_ id: UUID) {
        try? FileManager.default.removeItem(at: jobDirectory(id))
    }

    // ------------------------------------------------------------------
    // Enqueue
    // ------------------------------------------------------------------

    // Meeting stop path. The WAV write happens off-main at .utility (a
    // 90-minute meeting is ~330 MB per track); once this returns, the audio
    // is crash-safe on disk and MeetingPipeline can go back to .idle.
    func enqueueMeeting(
        mic: [Float], system: [Float], recordedAt: Date,
        engine: SettingsStore.Engine, whisperModel: String
    ) async throws {
        let job = TranscriptionJob(
            id: UUID(), createdAt: Date(), engine: engine, whisperModel: whisperModel,
            payload: .meeting(
                .init(
                    recordedAt: recordedAt,
                    duration: TimeInterval(mic.count) / 16_000.0,
                    hasSystemTrack: !system.isEmpty)))
        let dir = jobDirectory(job.id)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try WAVFile.write(samples: mic, to: dir.appendingPathComponent("mic.wav"))
            if !system.isEmpty {
                try WAVFile.write(samples: system, to: dir.appendingPathComponent("system.wav"))
            }
        }.value
        try persist(job)
        notifier.requestPermissionIfNeeded()
        append(job)
    }

    // File jobs (drops and retries). For drops the caller has already
    // decoded audio.wav into jobDirectory(jobID) and created the .queued
    // History entry; retries reference the entry's existing History WAV.
    func enqueueFile(
        jobID: UUID, entryID: UUID, sourceFilename: String, duration: TimeInterval,
        engine: SettingsStore.Engine, whisperModel: String, isRetry: Bool
    ) throws {
        let job = TranscriptionJob(
            id: jobID, createdAt: Date(), engine: engine, whisperModel: whisperModel,
            payload: .file(
                .init(
                    entryID: entryID, sourceFilename: sourceFilename,
                    duration: duration, isRetry: isRetry)))
        try persist(job)
        notifier.requestPermissionIfNeeded()
        append(job)
    }

    // Startup: re-enqueue every job left on disk (crash/quit recovery),
    // oldest first, then fail History entries whose job vanished.
    func scanAndResume() {
        let fm = FileManager.default
        let dirs =
            (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var found: [TranscriptionJob] = []
        for dir in dirs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("job.json")),
                let job = try? JSONDecoder().decode(TranscriptionJob.self, from: data)
            else {
                // Unreadable leftovers would fail forever on every launch.
                try? fm.removeItem(at: dir)
                continue
            }
            found.append(job)
        }
        found.sort { $0.createdAt < $1.createdAt }
        for job in found { append(job) }
        let active = Set(
            found.compactMap { job -> UUID? in
                if case .file(let p) = job.payload { return p.entryID }
                return nil
            })
        history.failOrphanedQueueEntries(activeIDs: active)
    }

    // ------------------------------------------------------------------
    // Worker
    // ------------------------------------------------------------------

    private func append(_ job: TranscriptionJob) {
        jobs.append(job)
        if case .file(let p) = job.payload { activeEntryIDs.insert(p.entryID) }
        refreshQueuedCount()
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
            guard let self else { return }
            self.worker = nil
            // An append that landed between drain()'s exit and this line saw
            // worker != nil and spawned nothing — pick its job up now.
            if !self.jobs.isEmpty { self.startWorkerIfNeeded() }
        }
    }

    private func drain() async {
        while let job = jobs.first {
            await process(job)
            jobs.removeFirst()
            if case .file(let p) = job.payload { activeEntryIDs.remove(p.entryID) }
        }
        state = .idle
    }

    // Test/support: suspends until the worker has drained everything.
    func waitUntilIdle() async {
        while let task = worker {
            await task.value
        }
    }

    private func process(_ job: TranscriptionJob) async {
        let resolved = engineResolver(job.engine, job.whisperModel)
        switch job.payload {
        case .meeting(let payload):
            await processMeeting(
                job, payload, engine: resolved.engine, engineLabel: resolved.label)
        case .file(let payload):
            await processFile(job, payload, engine: resolved.engine)
        }
    }

    // ------------------------------------------------------------------
    // File jobs
    // ------------------------------------------------------------------

    private func processFile(
        _ job: TranscriptionJob, _ payload: TranscriptionJob.FilePayload,
        engine: any TranscriptionEngine
    ) async {
        setProcessing(label: payload.sourceFilename, stage: "Transcribing", fraction: nil)
        // The retry gate (HistoryStore.beginRetry) is released here, not in
        // retryHistoryEntry — the job outlives that call by design.
        defer { if payload.isRetry { history.endRetry(payload.entryID) } }
        do {
            let audioURL: URL
            if payload.isRetry {
                guard let entry = history.entries.first(where: { $0.id == payload.entryID }),
                    let url = history.audioURL(for: entry)
                else { throw QueueError.audioMissing }
                audioURL = url
            } else {
                audioURL = jobDirectory(job.id).appendingPathComponent("audio.wav")
            }
            // Read + normalize off the main actor: a dropped multi-hour file
            // is hundreds of MB of Float32, and the UI must not pay for it.
            let prepared = try await Task.detached(priority: .utility) {
                let samples = try WAVFile.read(url: audioURL)
                return AudioPreprocessor.normalize(samples).samples
            }.value
            history.update(payload.entryID) { $0.status = .transcribing }
            let raw = try await engine.transcribe(samples: prepared) { [weak self] fraction in
                Task { @MainActor [weak self] in self?.setFraction(fraction) }
            }
            let processed = await postProcess(raw, payload.duration)
            history.update(payload.entryID) {
                $0.rawText = raw
                $0.processedText = processed
                $0.status = .ok
                $0.errorMessage = nil
                $0.engineUsed = AppCoordinator.engineUsedLabel(
                    engine: job.engine, modelName: job.whisperModel)
            }
            if !payload.isRetry { adoptAudioIntoHistory(from: audioURL, entryID: payload.entryID) }
            removeJobDir(job.id)
            notifier.notifyFileDone(filename: payload.sourceFilename)
        } catch {
            log.error(
                "File job failed (\(payload.sourceFilename, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
            history.update(payload.entryID) {
                $0.status = .failed
                $0.errorMessage = error.localizedDescription
            }
            if !payload.isRetry {
                // Keep the decoded audio when retention allows — Retry from
                // the entry stays possible after a transient failure.
                adoptAudioIntoHistory(
                    from: jobDirectory(job.id).appendingPathComponent("audio.wav"),
                    entryID: payload.entryID)
            }
            removeJobDir(job.id)
            notifier.notifyFailure(
                message: "Could not transcribe \(payload.sourceFilename).", revealURL: nil)
        }
    }

    // Moves the job's decoded WAV into History's audio directory when
    // retention keeps audio; otherwise it dies with the job dir (mirrors how
    // dictations behave under retention "Never").
    private func adoptAudioIntoHistory(from url: URL, entryID: UUID) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard history.retentionProvider().maxAge != nil else { return }
        let filename = "\(entryID.uuidString).wav"
        let dest = history.audioDirectory.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(
                at: history.audioDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: url, to: dest)
            history.update(entryID) { $0.audioFilename = filename }
        } catch {
            log.warning(
                "Could not adopt job audio for \(entryID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public) — entry stays text-only"
            )
        }
    }

    // ------------------------------------------------------------------
    // Meeting jobs
    // ------------------------------------------------------------------

    // The former MeetingPipeline.stop() body, working from persisted WAVs.
    // Mic-only: single ASR pass, every utterance is "You". Dual-track: the
    // echo-cancelled mic is the local user; the system track carries remote
    // participants and is diarized concurrently with the two ASR passes.
    private func processMeeting(
        _ job: TranscriptionJob, _ payload: TranscriptionJob.MeetingPayload,
        engine: any TranscriptionEngine, engineLabel: String
    ) async {
        let title = "Meeting (\(max(1, Int(payload.duration / 60))) min)"
        setProcessing(label: title, stage: "Preparing", fraction: nil)
        do {
            let dir = jobDirectory(job.id)
            // Read off the main actor: a 90-minute meeting is ~330 MB/track
            // of Float32, and the UI must not pay for decoding it.
            let (mic, system): ([Float], [Float]) = try await Task.detached(priority: .utility) {
                let mic = try WAVFile.read(url: dir.appendingPathComponent("mic.wav"))
                let system =
                    payload.hasSystemTrack
                    ? try WAVFile.read(url: dir.appendingPathComponent("system.wav")) : []
                return (mic, system)
            }.value
            let started = Date()
            let document: MeetingDocument.Output
            if system.isEmpty {
                setStage("Transcribing", fraction: nil)
                let asr = try await engine.transcribeDetailed(samples: mic) {
                    [weak self] fraction in
                    Task { @MainActor [weak self] in self?.setFraction(fraction) }
                }
                warnIfMissingTimings(asr, track: "mic")
                document = MeetingDocument.format(
                    localOnly: asr, duration: payload.duration,
                    recordedAt: payload.recordedAt, engineLabel: engineLabel)
            } else {
                // Echo cancellation is pure CPU work — keep it off the main
                // actor so the app stays responsive.
                let cleanedMic = await Task.detached(priority: .utility) {
                    EchoCanceller.process(mic: mic, reference: system)
                }.value
                async let remoteSegmentsTask = diarize(system)
                // Two sequential ASR passes share one progress bar, weighted
                // by how much audio each contributes.
                let remoteWeight = Double(system.count) / Double(system.count + cleanedMic.count)
                setStage("Transcribing", fraction: 0)
                let remoteASR = try await engine.transcribeDetailed(samples: system) {
                    [weak self] fraction in
                    Task { @MainActor [weak self] in self?.setFraction(fraction * remoteWeight) }
                }
                warnIfMissingTimings(remoteASR, track: "remote")
                let localASR = try await engine.transcribeDetailed(samples: cleanedMic) {
                    [weak self] fraction in
                    Task { @MainActor [weak self] in
                        self?.setFraction(remoteWeight + fraction * (1 - remoteWeight))
                    }
                }
                warnIfMissingTimings(localASR, track: "local")
                // A diarization failure (no remote speech, music, silence)
                // must not sink the meeting — transcripts survive unlabelled.
                let remoteSegments: [TimedSpeakerSegment]
                do {
                    remoteSegments = try await remoteSegmentsTask
                } catch {
                    log.error(
                        "Meeting diarization failed (\(error.localizedDescription, privacy: .public)) - saving without remote speaker labels."
                    )
                    remoteSegments = []
                }
                document = MeetingDocument.format(
                    localASR: localASR, remoteASR: remoteASR, remoteSegments: remoteSegments,
                    duration: payload.duration, recordedAt: payload.recordedAt,
                    engineLabel: engineLabel)
            }
            let url = try writeDocument(document)
            log.info(
                "Meeting job done in \(String(format: "%.2f", Date().timeIntervalSince(started)), privacy: .public)s → \(url.path, privacy: .public)"
            )
            setStage("Summarizing", fraction: nil)
            let summaryURL = await summarize(url)
            removeJobDir(job.id)
            notifier.notifyMeetingDone(title: title, revealURL: summaryURL ?? url)
        } catch {
            log.error(
                "Meeting job failed: \(error.localizedDescription, privacy: .public)")
            let salvaged = salvageMeetingAudio(job, payload)
            removeJobDir(job.id)
            notifier.notifyFailure(
                message:
                    "Meeting transcription failed. The audio was saved to your Meetings folder.",
                revealURL: salvaged)
        }
    }

    // Non-empty text with zero token timings silently loses speaker
    // attribution (some Whisper models lack an alignment head) — this is the
    // only trace of that degradation.
    private func warnIfMissingTimings(_ result: DetailedTranscription, track: String) {
        guard result.tokens.isEmpty else { return }
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        log.warning(
            "ASR[\(track, privacy: .public)]: non-empty text with no token timings - speaker attribution disabled for this track."
        )
    }

    // Copies the job's WAVs into the Meetings folder so a failed job never
    // loses the recording. Returns the mic WAV's destination (nil when even
    // the salvage failed — logged, nothing more we can do).
    private func salvageMeetingAudio(
        _ job: TranscriptionJob, _ payload: TranscriptionJob.MeetingPayload
    ) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: payload.recordedAt)
        let dir = salvageDirectory()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let micDest = dir.appendingPathComponent("Meeting \(stamp) (audio only).wav")
            try? fm.removeItem(at: micDest)
            try fm.copyItem(
                at: jobDirectory(job.id).appendingPathComponent("mic.wav"), to: micDest)
            if payload.hasSystemTrack {
                let sysDest = dir.appendingPathComponent(
                    "Meeting \(stamp) (audio only, system).wav")
                try? fm.removeItem(at: sysDest)
                try fm.copyItem(
                    at: jobDirectory(job.id).appendingPathComponent("system.wav"), to: sysDest)
            }
            return micDest
        } catch {
            log.error(
                "Meeting audio salvage failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // ------------------------------------------------------------------
    // State publishing
    // ------------------------------------------------------------------

    private func setProcessing(label: String, stage: String, fraction: Double?) {
        state = .processing(
            label: label, stage: stage, fraction: fraction, queued: max(0, jobs.count - 1))
    }

    func setStage(_ stage: String, fraction: Double?) {
        guard case .processing(let label, _, _, let queued) = state else { return }
        state = .processing(label: label, stage: stage, fraction: fraction, queued: queued)
    }

    private func setFraction(_ fraction: Double) {
        guard case .processing(let label, let stage, _, let queued) = state else { return }
        state = .processing(
            label: label, stage: stage, fraction: min(1, max(0, fraction)), queued: queued)
    }

    private func refreshQueuedCount() {
        guard case .processing(let label, let stage, let fraction, _) = state else { return }
        state = .processing(
            label: label, stage: stage, fraction: fraction, queued: max(0, jobs.count - 1))
    }
}
