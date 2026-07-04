import AppKit
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
    private let hud: RecordingHUD
    private let queue: TranscriptionQueue
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

    init(hud: RecordingHUD, queue: TranscriptionQueue) {
        self.hud = hud
        self.queue = queue
    }

    func toggle() {
        if hud.shouldIgnorePress(whileBusy: false) { return }
        switch state {
        case .idle, .error:
            start()
        case .recording:
            Task { await stop() }
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

    // Stop is now persist-and-enqueue: the WAVs land in the queue's job
    // directory (crash-safe), the pipeline returns to .idle immediately —
    // a new meeting can start while the previous one transcribes — and the
    // queue owns everything that used to run inline here (echo cancel,
    // diarization, ASR, document, summary).
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
        guard samples.count >= 16_000 * 2 else {
            // Less than 2 s of audio is almost always an accidental tap.
            state = .idle
            hud.hide()
            return
        }
        state = .idle
        do {
            try await queue.enqueueMeeting(
                mic: samples, system: systemCaptureResult.samples, recordedAt: Date(),
                engine: SettingsStore.shared.meetingEngine,
                whisperModel: SettingsStore.shared.modelName)
            hud.showMessage("Transcribing in the background…", autoHideAfter: 3)
        } catch {
            // Disk full or unwritable queue dir: salvage straight to the
            // Meetings folder before giving up — the recording must survive.
            log.error(
                "Meeting enqueue failed: \(error.localizedDescription, privacy: .public)")
            let saved = salvageDirectly(
                mic: samples, system: systemCaptureResult.samples)
            hud.showMessage(
                saved
                    ? "Couldn't queue the transcription — audio saved to your Meetings folder."
                    : "Couldn't save the meeting audio. Check free disk space.",
                autoHideAfter: 5)
        }
        maybeShowSystemAudioNotice(silentButActive: systemCaptureResult.silentButActive)
    }

    // Last-resort persistence when even the queue directory is unwritable.
    private func salvageDirectly(mic: [Float], system: [Float]) -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: Date())
        let dir = MeetingDocument.meetingsDirectory()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try WAVFile.write(
                samples: mic, to: dir.appendingPathComponent("Meeting \(stamp) (audio only).wav"))
            if !system.isEmpty {
                try WAVFile.write(
                    samples: system,
                    to: dir.appendingPathComponent("Meeting \(stamp) (audio only, system).wav"))
            }
            return true
        } catch {
            log.error(
                "Meeting direct salvage failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
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
