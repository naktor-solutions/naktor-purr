import AppKit
import FluidAudio
import Foundation
import os.log

// Meeting recording flow.
//
// In-memory recording is the simplest approach. A 90-minute meeting at
// 16 kHz × Float32 mono is ~330 MB - comfortable on every Apple Silicon
// Mac. If users push past that we'd add WAV-to-disk; for now we document
// the practical limit.
@MainActor
final class MeetingPipeline: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case processing
        case error(String)
    }

    @Published private(set) var state: State = .idle {
        didSet {
            if oldValue != state {
                log.info(
                    "Meeting state: \(String(describing: oldValue), privacy: .public) -> \(String(describing: self.state), privacy: .public)"
                )
            }
        }
    }

    private let recorder = AudioRecorder()
    // SystemAudioCapture (macOS 14.2+) held type-erased so this class still
    // builds against the macOS 14.0 deployment target. nil when system audio
    // is unavailable or failed to start - the meeting is mic-only then.
    private var systemCapture: AnyObject?
    // Resolved at stop() time, not when the pipeline is built or when
    // recording starts - so whatever engine is selected in Settings when
    // processing begins wins, even if the user changed it mid-recording.
    // The label feeds the transcript header ("_Engine: ..._").
    private let engineProvider: () -> (engine: any TranscriptionEngine, label: String)
    private let diarizer = Diarizer()
    private let hud: RecordingHUD
    private let summarizer: MeetingSummarizer
    private var elapsedTimer: Timer?
    private var levelTask: Task<Void, Never>?
    private var systemLevelTask: Task<Void, Never>?
    // Latest system-audio RMS (0 when the tap is silent or absent). Blended with
    // the mic level so the HUD waveform reacts to remote/system sound; decays on
    // each mic tick because a silent tap stops delivering buffers (and levels).
    private var latestSystemLevel: Float = 0

    // Per-mic-tick decay applied to the cached system level so a stopped tap
    // (no buffers delivered during silence) fades the waveform back to rest.
    private static let systemLevelDecay: Float = 0.8

    private let log = Logger(subsystem: "com.naktor.barktor", category: "meeting")

    init(
        hud: RecordingHUD,
        summarizer: MeetingSummarizer,
        engineProvider: @escaping () -> (engine: any TranscriptionEngine, label: String)
    ) {
        self.hud = hud
        self.summarizer = summarizer
        self.engineProvider = engineProvider
    }

    func unloadDiarizer() {
        diarizer.unload()
    }

    func downloadDiarizer() async throws {
        try await diarizer.downloadAndWarmup()
    }

    // .recording is excluded - a press during recording is the *stop* gesture.
    // The merge/processing pass must never be interrupted or duplicated.
    private var meetingBusy: Bool {
        if case .processing = state { return true }
        return false
    }

    func toggle() {
        if hud.shouldIgnorePress(whileBusy: meetingBusy) { return }
        switch state {
        case .idle, .error:
            start()
        case .recording:
            Task { await stop() }
        case .processing:
            // Refuse to interrupt - the merge pass takes a few seconds and
            // restarting mid-merge would be error-prone.
            break
        }
    }

    private func start() {
        do {
            try recorder.start()
            startSystemCapture()
            state = .recording(startedAt: Date())
            // The recording pill is opt-out (Settings → Features). When hidden
            // the meeting still records; the menu bar carries the indicator.
            if SettingsStore.shared.showMeetingHUD {
                hud.show(.meeting(elapsed: 0))
                startElapsedTimer()
            }
            startLevelTask()
        } catch {
            log.error("Meeting recorder failed to start: \(error.localizedDescription, privacy: .public)")
            state = .error("Could not start microphone: \(error.localizedDescription)")
            hud.showMessage(
                HUDErrorText.message(for: error) ?? "Could not start the microphone. Try again.",
                autoHideAfter: 4)
        }
    }

    // Best-effort system-audio capture for meeting mode (macOS 14.2+). A
    // failure here is non-fatal: the meeting still records the microphone,
    // it just won't include the remote call participants.
    private func startSystemCapture() {
        guard #available(macOS 14.2, *) else { return }
        let capture = SystemAudioCapture()
        do {
            try capture.start()
            systemCapture = capture
        } catch {
            log.error(
                "System audio capture failed to start: \(error.localizedDescription, privacy: .public)"
            )
            systemCapture = nil
        }
    }

    // Tears down system-audio capture and returns whatever was captured.
    // Empty when system audio was never running.
    private func stopSystemCapture(
        micStartHostTime: UInt64
    ) -> (
        samples: [Float], silentButActive: Bool
    ) {
        defer { systemCapture = nil }
        guard #available(macOS 14.2, *),
            let capture = systemCapture as? SystemAudioCapture
        else { return ([], false) }
        let captured = capture.stop(alignedTo: micStartHostTime)
        return (captured, capture.lastCaptureSilentButActive)
    }

    // One-time, actionable notice when a meeting captured silent system audio:
    // the output device was active but the System Audio Recording permission is
    // off, so the tap delivered only zeros. The transcript still saved mic-only;
    // this tells the user why remote voices are missing and links to the pane.
    private func maybeShowSystemAudioNotice(silentButActive: Bool) {
        guard silentButActive, !SettingsStore.shared.systemAudioNoticeShown else { return }
        let alert = NSAlert()
        alert.messageText = "System audio wasn't captured"
        alert.informativeText =
            "This meeting saved your microphone only. To include remote voices, allow Barktor under System Settings → Privacy & Security → Screen & System Audio Recording, then record again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        // Barktor is a menu-bar accessory app and the stop path just revealed the
        // transcript in Finder, so without activating first the modal opens
        // behind the frontmost app and the user never sees it. Bring Barktor
        // forward so the alert is actually on top.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        // Consume the one-time flag only after the alert is dismissed - if it
        // were set before runModal() (or before activation), a notice the user
        // never actually saw would still disable it forever.
        SettingsStore.shared.systemAudioNoticeShown = true
        if response == .alertFirstButtonReturn {
            Permissions.openSystemAudioSettings()
        }
    }

    private func stop() async {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        levelTask?.cancel()
        levelTask = nil
        systemLevelTask?.cancel()
        systemLevelTask = nil
        latestSystemLevel = 0
        let samples = recorder.stop()
        // Align the tap to the mic's continuous timeline; the tap omits silent
        // gaps, so its raw timestamps don't share the mic's clock origin.
        let systemCaptureResult = stopSystemCapture(micStartHostTime: recorder.captureStartHostTime)
        let systemSamples = systemCaptureResult.samples
        guard samples.count >= 16_000 * 2 else {
            // Less than 2 s of audio is almost always an accidental tap.
            state = .idle
            hud.hide()
            return
        }
        state = .processing
        hud.show(.transcribing)
        let (engine, engineLabel) = engineProvider()

        do {
            let processingStarted = Date()
            log.info(
                "Meeting processing: \(samples.count, privacy: .public) mic samples + \(systemSamples.count, privacy: .public) system samples (~\(String(format: "%.2f", Double(samples.count) / 16_000.0), privacy: .public)s)"
            )
            let duration = TimeInterval(samples.count) / 16_000.0
            let document: MeetingDocument.Output
            if systemSamples.isEmpty {
                // Mic-only: the microphone is the local user, so every
                // utterance is "You" (source beats voice). No diarization runs
                // on the mic track - it can't reliably tell in-room speakers
                // apart anyway, and skipping it means a short or quiet solo clip
                // can never be rejected with "no speech detected".
                let asr = try await engine.transcribeDetailed(samples: samples)
                logASRResult(asr, track: "mic")
                warnIfMissingTimings(asr, track: "mic")
                log.info(
                    "Meeting transcribe complete in \(String(format: "%.2f", Date().timeIntervalSince(processingStarted)), privacy: .public)s: \(asr.tokens.count, privacy: .public) tokens, single local speaker (You)"
                )
                document = MeetingDocument.format(
                    localOnly: asr,
                    duration: duration,
                    recordedAt: Date(),
                    engineLabel: engineLabel
                )
            } else {
                // Two tracks: the system audio carries the remote participants
                // (diarized into Speaker N); the echo-cancelled microphone
                // carries the local user (labelled You). The two ASR passes
                // run sequentially on the same engine; diarization runs
                // concurrently with them.
                // Echo cancellation is pure CPU work; run it off the main
                // actor so the HUD stays responsive during processing.
                let cleanedMic = await Task.detached {
                    EchoCanceller.process(mic: samples, reference: systemSamples)
                }.value
                async let remoteSegmentsTask = diarizer.diarize(samples: systemSamples)
                let remoteASR = try await engine.transcribeDetailed(samples: systemSamples)
                warnIfMissingTimings(remoteASR, track: "remote")
                let localASR = try await engine.transcribeDetailed(samples: cleanedMic)
                warnIfMissingTimings(localASR, track: "local")
                // As in the mic-only path, a diarization failure on the system
                // track (no remote speech, music, near-silence) must not sink
                // the meeting. Keep both transcripts; the remote side just
                // won't carry Speaker N labels.
                let remoteSegments: [TimedSpeakerSegment]
                do {
                    remoteSegments = try await remoteSegmentsTask
                } catch {
                    log.error(
                        "Meeting diarization failed on the system track (\(error.localizedDescription, privacy: .public)) - saving transcripts without remote speaker labels."
                    )
                    remoteSegments = []
                }
                log.info(
                    "Meeting dual-track complete in \(String(format: "%.2f", Date().timeIntervalSince(processingStarted)), privacy: .public)s: local \(localASR.tokens.count, privacy: .public) tokens, remote \(remoteASR.tokens.count, privacy: .public) tokens, \(remoteSegments.count, privacy: .public) speaker segments"
                )
                document = MeetingDocument.format(
                    localASR: localASR,
                    remoteASR: remoteASR,
                    remoteSegments: remoteSegments,
                    duration: duration,
                    recordedAt: Date(),
                    engineLabel: engineLabel
                )
            }
            let url = try MeetingDocument.write(document)
            log.info("Meeting saved → \(url.path, privacy: .public)")

            // Optional: run on-device summarization. We always reveal the
            // best file in Finder - summary if it exists, transcript
            // otherwise - so the user lands on what they want to read.
            let summary = await runSummaryIfEnabled(transcriptURL: url)
            switch summary {
            case .produced(let sidecarURL):
                NSWorkspace.shared.activateFileViewerSelecting([sidecarURL])
                hud.hide()
            case .skipped:
                NSWorkspace.shared.activateFileViewerSelecting([url])
                hud.hide()
            case .failed:
                // The HUD is showing the summary-failure message, which
                // auto-hides itself - hiding here would cut it off.
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            maybeShowSystemAudioNotice(silentButActive: systemCaptureResult.silentButActive)
            state = .idle
        } catch {
            log.error("Meeting pipeline failed: \(error.localizedDescription, privacy: .public)")
            state = .error(error.localizedDescription)
            let mapped = HUDErrorText.message(for: error)
            hud.showMessage(mapped ?? "Meeting processing failed. Try again.", autoHideAfter: 4)
            try? await Task.sleep(for: .seconds(4))
            state = .idle
        }
    }

    // Outcome of the optional summarization pass. The transcript is already
    // on disk by the time summarization runs, so a failure is non-fatal -
    // but it is no longer silent: `.failed` means the reason is on the HUD.
    private enum SummaryOutcome {
        case produced(URL)  // sidecar .summary.md was written
        case skipped  // toggle off, or no backend installed
        case failed  // backend failed - reason shown on the HUD
    }

    // Runs on-device summarization when the toggle is on and a backend is
    // ready. On failure the transcript still stands; we surface why on the
    // HUD rather than swallowing it, so a missing summary isn't a mystery.
    private func runSummaryIfEnabled(transcriptURL: URL) async -> SummaryOutcome {
        guard SettingsStore.shared.summarizeMeetings else {
            log.info("Summary skipped: auto-summarize toggle is off.")
            return .skipped
        }
        let backend = MeetingSummarizer.currentBackend()
        log.info("Summary backend resolved: \(String(describing: backend), privacy: .public)")
        guard MeetingSummarizer.canSummarizeNow else {
            log.info("Summary skipped: no backend available (Apple FM off + Gemma not installed).")
            return .skipped
        }
        hud.show(.summarizing)
        let started = Date()
        do {
            let url = try await summarizer.summarize(transcriptURL: transcriptURL)
            let elapsed = Date().timeIntervalSince(started)
            log.info(
                "Summary saved in \(String(format: "%.2f", elapsed), privacy: .public)s → \(url.path, privacy: .public)"
            )
            return .produced(url)
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            log.error(
                "Meeting summary failed after \(String(format: "%.2f", elapsed), privacy: .public)s: \(error.localizedDescription, privacy: .public)"
            )
            // The transcript saved fine - a silently missing summary leaves
            // the user guessing, so put the reason on the HUD briefly.
            hud.showMessage(Self.summaryFailureMessage(error), autoHideAfter: 4)
            return .failed
        }
    }

    // Short HUD copy for a summarization failure. The cases that embed a raw
    // underlying error get a clean generic line here (the full detail is
    // already in the log via the catch above); only the cases with their own
    // actionable user-facing text are surfaced verbatim.
    private static func summaryFailureMessage(_ error: Error) -> String {
        let generic = "Meeting summary failed. Your transcript was saved."
        guard let summarizerError = error as? MeetingSummarizer.SummarizerError else {
            return generic
        }
        switch summarizerError {
        case .backendUnavailable:
            return "Meeting summaries need an AI model. Set one up in Settings → Features."
        case .unsupportedLocale:
            return summarizerError.errorDescription ?? generic
        case .contentFlagged(let reason):
            // The on-device guardrail tripped and no Gemma fallback was installed;
            // surface the model's own reason verbatim rather than a vague generic.
            return "Summary failed: \"\(reason)\""
        case .modelLoadFailed, .emptyResponse, .generationFailed:
            return generic
        }
    }

    // Detailed ASR diagnostics. The "no speech detected" failures were invisible
    // from the existing logs because we never recorded what the engine returned -
    // this surfaces counts without copying transcript content into unified logs.
    private func logASRResult(_ result: DetailedTranscription, track: String) {
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        log.info(
            "ASR[\(track, privacy: .public)]: \(result.text.count, privacy: .public) chars, \(result.tokens.count, privacy: .public) tokens, audio \(String(format: "%.2f", result.duration), privacy: .public)s, empty \(trimmed.isEmpty, privacy: .public)"
        )
    }

    // Some engines (e.g. Whisper models without an alignment head) can return
    // non-empty text with zero token timings. MeetingDocument still keeps that
    // text (as an unattributed fallback utterance), but the track silently
    // loses speaker/diarization attribution - this is the only trace of that
    // degradation, since it never surfaces as an error.
    private func warnIfMissingTimings(_ result: DetailedTranscription, track: String) {
        guard result.tokens.isEmpty else { return }
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        log.warning(
            "ASR[\(track, privacy: .public)]: non-empty text with no token timings - speaker attribution disabled for this track."
        )
    }

    private func startElapsedTimer() {
        guard case .recording(let startedAt) = state else { return }
        // Schedule on the common runloop mode so the timer keeps firing
        // while the user drags windows, scrolls menus, or holds a mouse
        // button - default mode would silently pause the clock during any
        // of those interactions and leave the HUD frozen on the last value.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, case .recording = self.state else { return }
                let now = Date().timeIntervalSince(startedAt)
                // update(_:) only mutates the label; show(_:) would also
                // reorder+reposition every 0.5 s, which fires SwiftUI's
                // "Publishing changes from within view updates" warning.
                self.hud.update(.meeting(elapsed: now))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func startLevelTask() {
        // Drive the recording pill's live waveform from the mic RMS, blended with
        // the system-audio RMS so the wave reacts to remote/system sound too - the
        // mic alone stays flat when only the other side is talking. When the pill
        // is hidden we still drain the streams so they don't buffer unboundedly
        // over a long meeting - we just don't update the HUD.
        let feedsHUD = SettingsStore.shared.showMeetingHUD
        levelTask = Task { [weak self] in
            guard let self else { return }
            for await level in self.recorder.levels {
                if Task.isCancelled { break }
                // Fade the cached system level so a silent tap (no buffers) falls
                // back to rest instead of pinning the wave at its last loud value.
                self.latestSystemLevel *= Self.systemLevelDecay
                if feedsHUD { self.hud.updateLevel(max(level, self.latestSystemLevel)) }
            }
        }
        startSystemLevelTask()
    }

    // Mirrors the system-audio tap's RMS into `latestSystemLevel`. Best-effort:
    // a no-op when system capture is unavailable or didn't start, leaving the
    // HUD mic-only (its prior behaviour).
    private func startSystemLevelTask() {
        guard #available(macOS 14.2, *), let capture = systemCapture as? SystemAudioCapture else {
            return
        }
        systemLevelTask = Task { [weak self] in
            for await level in capture.levels {
                if Task.isCancelled { break }
                self?.latestSystemLevel = level
            }
        }
    }
}
