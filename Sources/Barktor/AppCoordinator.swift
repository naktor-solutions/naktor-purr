import AppKit
import Combine
import FluidAudio
import Foundation
import os.log

// Central orchestrator. Owns the audio + engine + insertion pipeline and is
// the only place where their lifecycles meet. Three flows live here, all
// driven by the multi-binding HotkeyManager:
//
// * **Dictation (transcribe)** - record while hotkey held, on release run
//   either batch transcribe + paste or EOU streaming + live typing.
//   Decided per-press by `shouldStreamThisRecording()`.
// * **Meeting** - tap-to-toggle long-form recording; on stop the audio is
//   persisted and handed to the background `TranscriptionQueue` (diarize,
//   ASR, document, summary all run there). Lives in `MeetingPipeline`.
// * **Voice edit** - hold while text is selected; transcribed speech is
//   parsed as an edit instruction and applied via Accessibility (or paste
//   fallback). Lives in `VoiceEditor`.
//
// While a meeting is recording, dictation is suspended at the hotkey
// layer - accidentally inserting batch transcripts mid-meeting would be
// bad. Voice-edit is independent and can fire any time - the queue never
// borrows the live dictation/voice-edit engine, so there's no shared-pipe
// hazard to gate against.
@MainActor
final class AppCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case error(String)
    }

    // Unified glyph state for the menu bar. Folds the three independent flows
    // (dictation `state`, voice-edit, meeting) into one signal so a single
    // status item can represent whichever one is active.
    enum MenuBarStatus: Equatable {
        case idle
        case recording
        case transcribing
        case meeting
        case error(String)
    }

    enum DiarizerDeleteResult {
        case ok
        case busy
        case failed(Error)
    }

    enum ModelDownloadResult {
        case ok
        case failed(Error)
    }

    enum DeleteAllModelsResult {
        case ok
        case busy
        case failed(Error)
    }

    @Published private(set) var state: State = .idle {
        didSet {
            // Equality check avoids spamming the log when the same state
            // is re-asserted (e.g. successive .recording transitions).
            if oldValue != state {
                log.info(
                    "State: \(String(describing: oldValue), privacy: .public) -> \(String(describing: self.state), privacy: .public)"
                )
            }
            // Catch-all restore for paths that quiet the audio but never reach
            // finishRecording/cancelDictation - the streaming-startup abort and
            // the error transitions. No-op on the normal path (those already
            // restored and reset activeAudioAction to .none).
            switch state {
            case .idle, .error: restoreAudioIfNeeded()
            case .recording, .transcribing: break
            }
            refreshSafeToQuit()
            refreshMenuBarStatus()
        }
    }

    // Mirror of canQuitSafely() as a @Published flag so SwiftUI views (the
    // updater UI) can disable destructive actions when a recording / meeting
    // is in flight. Recomputed from coordinator state + meeting state.
    @Published private(set) var safeToQuit: Bool = true

    // Single signal the menu bar observes. Recomputed whenever any of the
    // three flows changes state (see refreshMenuBarStatus()).
    @Published private(set) var menuBarStatus: MenuBarStatus = .idle

    // 0..1 while the Parakeet TDT v2 weights are downloading, nil otherwise.
    // Fed by ParakeetEngine.onBatchProgress and used by the Engine tab's
    // Parakeet card so an automatic warm-up download shows a live progress bar
    // too - not just a manual Download tap (which previously was the only path
    // the card could observe).
    @Published private(set) var parakeetBatchProgress: Double?

    // Same, for the EOU streaming model (Smart Typing). Lets the Smart Typing
    // card show a live bar when warm-up downloads EOU, not just a manual tap.
    @Published private(set) var eouDownloadProgress: Double?

    // 0..1 while the Nemotron multilingual weights download, nil otherwise.
    // Fed by NemotronStreamingEngine.onProgress; read by its Settings card.
    @Published private(set) var nemotronProgress: Double?

    // True while a meeting session is in flight (recording or processing).
    // Feeds menuBarStatus; a meeting outranks dictation/voice-edit for the glyph.
    private var meetingActive = false

    // Mirror of voiceEditor.state, updated from the value the observer emits.
    // We must NOT read voiceEditor.state inside its own sink: @Published emits
    // during willSet, so the property still holds the PREVIOUS value there.
    // Reading it would leave the glyph a step behind - and stick the transcribe
    // icon on screen after a voice edit ends (the .transcribing→.idle emission
    // would compute from the stale .transcribing). Mirroring the emitted value
    // sidesteps that entirely.
    private var voiceEditState: VoiceEditor.State = .idle

    private let recorder = AudioRecorder()
    private let inserter = TextInserter()
    private let hud = RecordingHUD()
    private let hotkey = HotkeyManager()

    // Engine is rebuilt whenever the user switches between Parakeet and
    // Whisper in Settings. We keep one alive at a time to avoid loading
    // both ~1GB pipes into memory.
    private var engine: any TranscriptionEngine = ParakeetEngine()
    private var parakeet = ParakeetEngine()
    private var parakeetV3 = ParakeetEngine(version: .v3)
    // Nemotron multilingual streaming — the only multilingual engine that
    // supports Smart Typing (Parakeet v3 and Whisper are batch-only).
    private var nemotron = NemotronStreamingEngine()
    // Owned here (not by MeetingPipeline) since the queue is what diarizes
    // now; Settings' download/unload flows reach it through the coordinator.
    private let diarizer = Diarizer()
    private let summarizer = MeetingSummarizer.shared
    private var meeting: MeetingPipeline!
    private var voiceEditor: VoiceEditor!
    private var meetingObserver: AnyCancellable?
    private var voiceEditObserver: AnyCancellable?

    // Recordings shorter than this are accidental taps - not worth an entry.
    private static let minKeepSamples = 16_000 * 4 / 10

    private var levelTask: Task<Void, Never>?
    // When the current dictation entered the recording state. Lets us tell a
    // genuine "held the key and spoke but the mic was still waking" failure
    // from a quick accidental tap.
    private var recordingStartedAt: Date?
    private var streamingTask: Task<(raw: String, processed: String), Never>?
    private var streamingSession: (any StreamingSession)?
    // The audio-feed loop, pumping recorder.chunks into the streaming session.
    // Owned here (not nested in streamingTask) so finishStreamingRecording()
    // can await it - draining every buffered chunk into the session - before
    // calling finish(). See beginStreamingRecording / finishStreamingRecording.
    private var feedTask: Task<Void, Never>?
    // Streaming sessions need an `await` to load - meanwhile the user might
    // already release the hotkey. We track that intent here so the in-flight
    // setup task can bail out instead of starting a recording nobody wants.
    private var streamingStartupInFlight = false
    private var releasedDuringStartup = false
    // Set by cancelStreamingRecording() so runStreamingTask's post-loop
    // trailing-space insert knows to stay silent - Esc means no further
    // insertion, full stop.
    private var streamingCancelledByUser = false

    // What we did to other apps' audio at this dictation's start, so we undo
    // exactly that on stop (see SettingsStore.recordingAudio / MediaController).
    // .muted carries the device's prior mute flag so we restore it, not just
    // clear it.
    private enum ActiveAudioAction { case none, muted(wasMuted: Bool) }
    private var activeAudioAction: ActiveAudioAction = .none

    // Quit callback delivered by AppDelegate. Stored so the global tap hotkey
    // can drive the same code path as the status-bar Quit menu item.
    private var onQuit: (() -> Void)?

    private let log = Logger(subsystem: "com.naktor.barktor", category: "coordinator")
    // Streaming post-processing trace, kept on its own category so the
    // per-utterance flow can be followed without the coordinator's
    // state-transition noise. Same category as PostProcessor's own logs.
    private let postLog = Logger(subsystem: "com.naktor.barktor", category: "postprocess")

    func setMenuActions(quit: @escaping () -> Void) {
        self.onQuit = quit
    }

    func start() {
        rebuildEngine(initial: true)

        // Mirror the Parakeet batch download's progress into a @Published the
        // Engine tab observes, so warm-up and manual downloads both drive the
        // card's progress bar through one path.
        parakeet.onBatchProgress = { [weak self] fraction in
            self?.parakeetBatchProgress = fraction
        }
        parakeet.onEOUProgress = { [weak self] fraction in
            self?.eouDownloadProgress = fraction
        }
        // v3 shares the same batch-progress @Published; only one Parakeet
        // variant is active (and downloading) at a time.
        parakeetV3.onBatchProgress = { [weak self] fraction in
            self?.parakeetBatchProgress = fraction
        }
        nemotron.onProgress = { [weak self] fraction in
            self?.nemotronProgress = fraction
        }

        // Smart Typing requires the EOU model, and that model is fetched only
        // from its explicit Download button - which is what enables the toggle.
        // If a stale "on" state persists without the model on disk (carried over
        // from an older build, or EOU removed), turn it off rather than letting
        // warm-up or a dictation silently pull ~440 MB. The user re-enables it
        // after downloading EOU. Never the other way round.
        if SettingsStore.shared.smartTyping, !ParakeetEngine.eouIsInstalled() {
            SettingsStore.shared.smartTyping = false
        }

        // Keep the mic warm between presses; the recorder self-skips warming
        // on Bluetooth to avoid pinning it to SCO mode.
        recorder.allowsWarmKeeping = true

        // Every AudioRecorder (dictation, voice edit, meeting) opens the mic the user
        // pinned in Settings; "" falls back to the system default.
        AudioRecorder.preferredInputUID = { SettingsStore.shared.inputDeviceUID }

        HistoryStore.shared.retentionProvider = { SettingsStore.shared.historyAudioRetention }
        HistoryStore.shared.startDailySweeps()

        meeting = MeetingPipeline(hud: hud, queue: TranscriptionQueue.shared)
        voiceEditor = VoiceEditor(hud: hud) { [weak self] in
            // Voice-edit always uses whichever engine the user has selected
            // - they may want fast Tiny EN for edits even if Parakeet is
            // their dictation default.
            self?.engine ?? ParakeetEngine()
        }

        // While a meeting is recording, hotkey-level dictation is gated so
        // the user can't insert a transcript over their notes by reflex.
        meetingObserver = meeting.$state.sink { [weak self] state in
            guard let self else { return }
            switch state {
            case .recording:
                self.hotkey.suspendDictation(true)
                self.meetingActive = true
            case .idle, .error:
                self.hotkey.suspendDictation(false)
                self.meetingActive = false
            }
            self.refreshSafeToQuit()
            self.refreshMenuBarStatus()
        }

        // Voice edit drives the HUD directly and never touches `state`, so the
        // menu bar would otherwise miss it - mirror its activity into the glyph.
        // Use the emitted value (not voiceEditor.state) - see voiceEditState.
        voiceEditObserver = voiceEditor.$state.sink { [weak self] newState in
            guard let self else { return }
            self.voiceEditState = newState
            self.refreshMenuBarStatus()
        }

        installHotkeys()
        // Eager warmup so the first press doesn't pay model-load cost.
        Task { await engine.warmup() }
    }

    func reloadEngine() {
        rebuildEngine(initial: false)
        Task { await engine.warmup() }
    }

    // After a Whisper model finishes downloading (Settings), load and
    // ANE-compile it now - under the download's own progress - rather than on
    // the user's first dictation. No-op unless it's the active engine's model.
    func warmupDownloadedModel(_ modelName: String) {
        guard SettingsStore.shared.engine == .whisper,
            SettingsStore.shared.modelName == modelName
        else { return }
        Task { await engine.warmup() }
    }

    func reinstallHotkey() {
        installHotkeys()
    }

    // While the Settings hotkey recorder is listening, mute the live tap so the
    // keys the user presses to bind a hotkey don't also fire dictation.
    func setHotkeyCapture(active: Bool) {
        hotkey.setPaused(active)
    }

    // Refuses while a meeting is in flight so we don't pull the mmap out from under the running session.
    @discardableResult
    func deleteDiarizationModel() -> DiarizerDeleteResult {
        switch meeting.state {
        case .recording: return .busy
        case .idle, .error: break
        }
        diarizer.unload()
        do {
            try Diarizer.delete()
        } catch {
            return .failed(error)
        }
        SettingsStore.shared.meetingEnabled = false
        installHotkeys()
        log.info("Diarizer delete: on-disk removed; meetingEnabled flipped off.")
        return .ok
    }

    func downloadDiarizationModel() async -> ModelDownloadResult {
        do {
            try await diarizer.downloadAndWarmup()
            return .ok
        } catch {
            return .failed(error)
        }
    }

    func downloadEOUModel() async -> ModelDownloadResult {
        do {
            try await parakeet.downloadAndLoadStreamingManager()
            return .ok
        } catch {
            return .failed(error)
        }
    }

    func downloadParakeetModel(_ version: AsrModelVersion = .v2) async -> ModelDownloadResult {
        do {
            try await (version == .v2 ? parakeet : parakeetV3).downloadAndLoadBatchManager()
            return .ok
        } catch {
            return .failed(error)
        }
    }

    // Parakeet TDT v2 backs dictation, meetings, and voice editing, so refuse
    // while any of those is mid-flight rather than unloading the manager out
    // from under a running utterance.
    @discardableResult
    func deleteParakeetModel(_ version: AsrModelVersion = .v2) -> DiarizerDeleteResult {
        switch state {
        case .recording, .transcribing: return .busy
        case .idle, .error: break
        }
        if streamingSession != nil || streamingStartupInFlight { return .busy }
        if parakeetBatchProgress != nil { return .busy }
        switch meeting.state {
        case .recording: return .busy
        case .idle, .error: break
        }
        if voiceEditState != .idle { return .busy }
        (version == .v2 ? parakeet : parakeetV3).unloadBatchManager()
        do {
            try ParakeetEngine.batchDelete(version)
        } catch {
            return .failed(error)
        }
        log.info("Parakeet TDT \(version == .v2 ? "v2" : "v3", privacy: .public) batch deleted on user request.")
        return .ok
    }

    func downloadNemotronModel() async -> ModelDownloadResult {
        do {
            try await nemotron.downloadAndLoad()
            return .ok
        } catch {
            return .failed(error)
        }
    }

    func deleteNemotronModel() -> DiarizerDeleteResult {
        switch state {
        case .recording, .transcribing: return .busy
        case .idle, .error: break
        }
        if streamingSession != nil || streamingStartupInFlight { return .busy }
        if nemotronProgress != nil { return .busy }
        switch meeting.state {
        case .recording: return .busy
        case .idle, .error: break
        }
        if voiceEditState != .idle { return .busy }
        nemotron.unload()
        do {
            try NemotronStreamingEngine.deleteAll()
        } catch {
            return .failed(error)
        }
        log.info("Nemotron multilingual deleted on user request.")
        return .ok
    }

    @discardableResult
    func deleteEOUModel() -> DiarizerDeleteResult {
        // Refuse mid-session so we don't unload the manager out from
        // under an in-flight utterance.
        if streamingSession != nil { return .busy }
        if streamingStartupInFlight { return .busy }
        parakeet.unloadStreamingManager()
        do {
            try ParakeetEngine.eouDelete()
        } catch {
            return .failed(error)
        }
        SettingsStore.shared.smartTyping = false
        log.info("EOU delete: on-disk removed; smartTyping flipped off.")
        return .ok
    }

    // Wipes every downloaded model in one action (Parakeet batch + EOU, all
    // Whisper checkpoints, the diarizer, and the Gemma GGUF). Refuses while any
    // capture or generation is in flight so we never pull weights out from under
    // a running session. Releases the in-memory model handles first, then
    // removes the on-disk weights, then turns off the features whose model is
    // now gone - mirroring the per-model delete buttons. Meeting transcripts and
    // user preferences are left untouched.
    @discardableResult
    func deleteAllModels() async -> DeleteAllModelsResult {
        guard canQuitSafely() else { return .busy }
        if streamingSession != nil || streamingStartupInFlight { return .busy }
        if voiceEditState != .idle { return .busy }
        if parakeetBatchProgress != nil || eouDownloadProgress != nil || nemotronProgress != nil {
            return .busy
        }

        // Release every in-memory session so no deleted file stays mmap'd behind
        // a live handle (and so we reclaim the unified memory).
        await summarizer.unload()
        diarizer.unload()
        parakeet.unloadStreamingManager()
        parakeet.unloadBatchManager()
        parakeetV3.unloadBatchManager()
        nemotron.unload()

        do {
            try ModelManager.deleteAllModels()
        } catch {
            log.error("Delete all models failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error)
        }

        // Turn off features whose model just disappeared. Auto-summarize keeps
        // working when Apple's built-in model is available (it needs no
        // download), so only fall back to off when there's no backend left.
        let s = SettingsStore.shared
        s.smartTyping = false
        s.meetingEnabled = false
        let appleFallbackUsable: Bool
        if #available(macOS 26.0, *) {
            appleFallbackUsable = MeetingSummarizer.appleFoundationAvailable
        } else {
            appleFallbackUsable = false
        }
        if appleFallbackUsable {
            s.summaryBackend = .appleFoundation
        } else {
            s.summarizeMeetings = false
        }

        // Drop the now-stale engine handle (a Whisper engine may still hold a
        // deleted model) and re-bind hotkeys to the flipped feature toggles. We
        // deliberately don't warm up here - that would immediately re-download.
        rebuildEngine(initial: false)
        installHotkeys()
        log.info("All models deleted; dependent features turned off.")
        return .ok
    }

    private func rebuildEngine(initial: Bool) {
        let chosen = SettingsStore.shared.engine
        switch chosen {
        case .parakeet:
            engine = parakeet
            parakeetV3.unloadBatchManager()  // don't hold both ~1GB pipes at once
            nemotron.unload()
        case .parakeetV3:
            engine = parakeetV3
            parakeet.unloadBatchManager()
            nemotron.unload()
        case .nemotron:
            engine = nemotron
            parakeet.unloadBatchManager()
            parakeetV3.unloadBatchManager()
        case .whisper:
            engine = WhisperEngine(modelName: SettingsStore.shared.modelName)
            nemotron.unload()
        }
        if !initial {
            log.info("Engine switched to \(chosen.rawValue, privacy: .public)")
        }
    }

    // Resolves the meeting-transcription engine: Parakeet reuses the shared
    // instance (expensive CoreML pipes), Whisper reuses the dictation engine
    // when the model matches, otherwise a fresh instance lazy-loads.
    // History retry deliberately does NOT use this - it resolves its own
    // engine (see retryHistoryEntry) to stay isolated from the live one.
    private func resolveEngine(_ choice: SettingsStore.Engine) -> (engine: any TranscriptionEngine, label: String) {
        switch choice {
        case .parakeet:
            return (parakeet, "Parakeet TDT v2")
        case .parakeetV3:
            return (parakeetV3, "Parakeet TDT v3")
        case .nemotron:
            return (nemotron, "Multilingual (Nemotron)")
        case .whisper:
            let model = SettingsStore.shared.modelName
            if let existing = engine as? WhisperEngine, existing.modelIdentifier == model {
                return (existing, "Whisper (\(model))")
            }
            return (WhisperEngine(modelName: model), "Whisper (\(model))")
        }
    }

    // Resolves the meeting-transcription engine from Settings at the moment a meeting stops.
    private func currentMeetingEngine() -> (engine: any TranscriptionEngine, label: String) {
        resolveEngine(SettingsStore.shared.meetingEngine)
    }

    private func installHotkeys() {
        // Reinstalling (e.g. after the user edits a trigger) must not leave a
        // stale lock or armed timer from the previous binding set behind.
        resetDictationGestureState()
        hotkey.onEscape = { [weak self] in self?.cancelDictation() }
        let s = SettingsStore.shared
        let trigger = s.dictationTrigger
        var bindings: [HotkeyManager.Binding] = [
            .init(
                action: .transcribe,
                hotkey: trigger.hotkey,
                onPress: { [weak self] in self?.handleTranscribePress(gesture: trigger.gesture) },
                onRelease: { [weak self] in self?.handleTranscribeRelease(gesture: trigger.gesture) }
            )
        ]
        if s.meetingEnabled {
            bindings.append(
                .init(
                    action: .meetingToggle,
                    hotkey: s.meetingHotkey,
                    onPress: { [weak self] in self?.meeting.toggle() },
                    onRelease: { /* tap-only; release is a no-op */  }
                ))
        }
        if s.voiceEditEnabled {
            bindings.append(
                .init(
                    action: .voiceEdit,
                    hotkey: s.voiceEditHotkey,
                    onPress: { [weak self] in self?.handleVoiceEditPress() },
                    onRelease: { [weak self] in self?.voiceEditor.handleRelease() }
                ))
        }
        // Global Quit hotkey. Hardcoded, always-on. Tap action, so release is
        // a no-op. Gated on `canQuitSafely()` to protect in-progress recordings
        // or transcriptions. Settings and Onboarding live in the menu bar
        // dropdown only - no global shortcut.
        bindings.append(
            .init(
                action: .quit,
                hotkey: .quitApp,
                onPress: { [weak self] in self?.handleQuitHotkey() },
                onRelease: {}
            ))
        hotkey.setBindings(bindings)
        hotkey.install()
    }

    private func handleVoiceEditPress() {
        voiceEditor.handlePress()
    }

    private func handleQuitHotkey() {
        guard canQuitSafely() else {
            log.info(
                "Quit hotkey ignored: in-progress state=\(String(describing: self.state), privacy: .public)"
            )
            return
        }
        onQuit?()
    }

    private func canQuitSafely() -> Bool {
        switch state {
        case .recording, .transcribing: return false
        case .idle, .error: break
        }
        if let meeting = meeting {
            switch meeting.state {
            case .recording: return false
            case .idle, .error: break
            }
        }
        return true
    }

    private func refreshSafeToQuit() {
        let next = canQuitSafely()
        if safeToQuit != next { safeToQuit = next }
    }

    private func refreshMenuBarStatus() {
        let next = computeMenuBarStatus()
        if menuBarStatus != next { menuBarStatus = next }
    }

    // Meeting outranks the per-press flows (it's the long-running capture and
    // gates dictation anyway). Dictation `state` is checked before voice-edit
    // only because that's the common path; the two don't run at once.
    private func computeMenuBarStatus() -> MenuBarStatus {
        if meetingActive { return .meeting }
        switch state {
        case .error(let message): return .error(message)
        case .transcribing: return .transcribing
        case .recording: return .recording
        case .idle:
            switch voiceEditState {
            case .transcribing: return .transcribing
            case .recording: return .recording
            case .idle: return .idle
            }
        }
    }

    // ------------------------------------------------------------------
    // Dictation hotkey lifecycle
    // ------------------------------------------------------------------

    // Non-interruptible dictation work. .recording is intentionally excluded:
    // in toggle mode a press during recording is the *stop* gesture, and in
    // hold-to-talk a re-press during recording is already a no-op in
    // beginRecording(). What must never be cut off or duplicated is the
    // post-capture transcription and the streaming-session startup.
    private var dictationBusy: Bool {
        if streamingStartupInFlight { return true }
        if case .transcribing = state { return true }
        return false
    }

    // Double-tap hands-free lock (hold gesture only). The arbiter owns the
    // timing rules; pendingHoldStop is the deferred-stop timer it arms.
    private var handsFree = HandsFreeLock()
    private var pendingHoldStop: Task<Void, Never>?
    // Armed first-tap timer for the double-tap-toggle gesture.
    private var doubleTapPending: Task<Void, Never>?

    // Clears every transient dictation-gesture timer/lock. Called before a
    // reinstall so a gesture in flight can't stop a recording started under a
    // different binding moments later.
    private func resetDictationGestureState() {
        handsFree.reset()
        cancelPendingHoldStop()
        doubleTapPending?.cancel()
        doubleTapPending = nil
    }

    private func handleTranscribePress(gesture: SettingsStore.Gesture) {
        if hud.shouldIgnorePress(whileBusy: dictationBusy) {
            log.info("Transcribe press ignored: HUD message up or transcription in flight.")
            return
        }
        // Overlap a cold Gemma load with the user speaking (EditInterpreter
        // does the same for voice edit). Only for batch dictations - Smart
        // Typing never LLM-processes.
        if SettingsStore.shared.llmPostProcessLevel != .off,
            !SettingsStore.shared.smartTyping,
            LLMModelManager.isInstalled()
        {
            Task { await LlamaRuntime.shared.warmUp() }
        }
        log.info(
            "Transcribe press received (state=\(String(describing: self.state), privacy: .public), gesture=\(gesture.rawValue, privacy: .public))"
        )
        switch gesture {
        case .hold:
            switch handsFree.press(at: ContinuousClock.now, recordingAlive: dictationAlive) {
            case .begin:
                cancelPendingHoldStop()
                beginRecording()
            case .lock:
                // Double-tap: the deferred stop is abandoned, the recording
                // keeps running with no key held until the next press. The
                // HUD staying up after the release is the feedback.
                cancelPendingHoldStop()
                log.info("Hands-free lock engaged - dictation runs until the next press.")
            case .stop:
                performHoldStop()
            }
        case .tapToggle:
            toggleDictation()
        case .doubleTapToggle:
            handleDoubleTapToggle()
        }
    }

    // One-tap start/stop, shared by tap-toggle and the completed double-tap.
    private func toggleDictation() {
        switch state {
        case .idle, .error: beginRecording()
        case .recording: Task { await finishRecording() }
        case .transcribing: break
        }
    }

    // Toggle on the second of two taps within the double-tap window; a lone tap
    // just arms (and later disarms) the timer, doing nothing.
    private func handleDoubleTapToggle() {
        if let pending = doubleTapPending {
            pending.cancel()
            doubleTapPending = nil
            toggleDictation()
        } else {
            doubleTapPending = Task { [weak self] in
                try? await Task.sleep(for: HandsFreeLock.secondPressWindow)
                guard let self, !Task.isCancelled else { return }
                self.doubleTapPending = nil
            }
        }
    }

    private func handleTranscribeRelease(gesture: SettingsStore.Gesture) {
        guard gesture == .hold else { return }
        log.info(
            "Transcribe release received (state=\(String(describing: self.state), privacy: .public), startupInFlight=\(self.streamingStartupInFlight, privacy: .public))"
        )
        switch handsFree.release(at: ContinuousClock.now) {
        case .ignore:
            break
        case .stop:
            performHoldStop()
        case .deferStop:
            // The hold was tap-short: hold the stop back briefly so a quick
            // second press can turn it into a hands-free lock instead.
            pendingHoldStop?.cancel()
            pendingHoldStop = Task { [weak self] in
                try? await Task.sleep(for: HandsFreeLock.secondPressWindow)
                guard let self, !Task.isCancelled else { return }
                self.pendingHoldStop = nil
                if self.handsFree.deferredStopFired() { self.performHoldStop() }
            }
        }
    }

    private var dictationAlive: Bool { state == .recording || streamingStartupInFlight }

    private func cancelPendingHoldStop() {
        pendingHoldStop?.cancel()
        pendingHoldStop = nil
    }

    // The stop half of hold-to-talk, shared by direct releases, deferred
    // (double-tap window) releases, and the locked-mode stop press. Stale
    // calls are safe: finishRecording guards on state, and re-flagging
    // releasedDuringStartup is idempotent.
    private func performHoldStop() {
        if state == .recording {
            Task { await finishRecording() }
        } else if streamingStartupInFlight {
            // User let go before the streaming session finished loading.
            // Mark the intent so the in-flight setup task tears down
            // cleanly instead of starting a recording the user has already
            // abandoned.
            releasedDuringStartup = true
        }
    }

    private func shouldStreamThisRecording() -> Bool {
        SettingsStore.shared.autoPaste
            && SettingsStore.shared.smartTyping
            && engine.supportsStreaming
    }

    private func beginRecording() {
        switch state {
        case .recording, .transcribing: return
        case .idle, .error: break
        }
        // A streaming session that's still loading counts as "starting up";
        // refusing here prevents a second press from kicking off a parallel
        // setup Task and leaving an orphaned session behind.
        if streamingStartupInFlight { return }

        // Mute other apps' audio for the duration of this dictation.
        switch SettingsStore.shared.recordingAudio {
        case .nothing: break
        case .mute: if let wasMuted = MediaController.mute() { activeAudioAction = .muted(wasMuted: wasMuted) }
        }

        if shouldStreamThisRecording() {
            beginStreamingRecording()
        } else {
            beginBatchRecording()
        }
    }

    // Undo whatever we did to other apps' audio at the start of this dictation.
    // Idempotent (resets to .none), so the stop/cancel paths can call it for an
    // instant restore while the state didSet stays as a catch-all for the abort
    // and error paths that never reach here.
    private func restoreAudioIfNeeded() {
        switch activeAudioAction {
        case .none: return
        case .muted(let wasMuted): MediaController.setMuted(wasMuted)
        }
        activeAudioAction = .none
    }

    private func finishRecording() async {
        // After an Esc cancel the hotkey release still arrives; the recorder
        // is already stopped and the Cancelled message is on the HUD - a
        // stale finish must not wipe it or re-enter the batch flow.
        guard state == .recording else { return }
        restoreAudioIfNeeded()
        SoundCues.play(.recordingStopped)
        if streamingSession != nil {
            await finishStreamingRecording()
        } else {
            await finishBatchRecording()
        }
    }

    // Esc during recording discards the dictation without ever calling an
    // engine. The audio still lands in history as a cancelled entry
    // (retryable), so a mistaken Esc loses nothing but the keystrokes.
    func cancelDictation() {
        guard state == .recording else { return }
        // Esc kills the dictation the lock refers to: drop the lock and any
        // deferred stop so the next press reads as a fresh start.
        handsFree.reset()
        cancelPendingHoldStop()
        restoreAudioIfNeeded()
        SoundCues.play(.dictationCancelled)
        if streamingSession != nil {
            // Close the TOCTOU window before the async teardown: the hotkey
            // release (or a second Esc, or a fresh press) that follows must
            // not find .recording while cancelStreamingRecording is still
            // awaiting - releases would race a second teardown and could
            // insert text after the cancel. .transcribing makes the release
            // guard and the press switch both treat us as busy until the
            // teardown's own state = .idle lands.
            state = .transcribing
            Task { await cancelStreamingRecording() }
        } else {
            cancelBatchRecording()
        }
    }

    private func cancelBatchRecording() {
        levelTask?.cancel()
        levelTask = nil
        recordingStartedAt = nil
        let samples = recorder.stop()
        let seconds = Double(samples.count) / 16_000.0
        if samples.count >= Self.minKeepSamples {
            let entryID = UUID()
            HistoryStore.shared.add(
                DictationEntry(
                    id: entryID, date: Date(), duration: seconds,
                    rawText: nil, processedText: nil,
                    engineUsed: Self.engineUsedLabel(
                        engine: SettingsStore.shared.engine,
                        modelName: SettingsStore.shared.modelName),
                    mode: .batch, status: .cancelled, errorMessage: nil, audioFilename: nil))
            HistoryStore.shared.persistAudio(id: entryID, samples: samples)
        }
        state = .idle
        hud.showMessage("Cancelled", autoHideAfter: 1.5)
    }

    private func cancelStreamingRecording() async {
        levelTask?.cancel()
        levelTask = nil
        recordingStartedAt = nil
        streamingCancelledByUser = true
        let samples = recorder.stop()
        let seconds = Double(samples.count) / 16_000.0
        hud.setPreviewActive(false)
        guard let session = streamingSession else {
            state = .idle
            hud.showMessage("Cancelled", autoHideAfter: 1.5)
            return
        }
        // Same teardown order as finishStreamingRecording's failure path:
        // cancel the session (closes the events stream), drain the consumer,
        // then kill the feed. No further text is inserted - the trailing
        // space is suppressed by streamingCancelledByUser.
        await session.cancel()
        let texts = await streamingTask?.value
        feedTask?.cancel()
        feedTask = nil
        streamingSession = nil
        streamingTask = nil
        if samples.count >= Self.minKeepSamples {
            let entryID = UUID()
            HistoryStore.shared.add(
                DictationEntry(
                    id: entryID, date: Date(), duration: seconds,
                    rawText: texts.flatMap { $0.raw.isEmpty ? nil : $0.raw },
                    processedText: texts.flatMap { $0.processed.isEmpty ? nil : $0.processed },
                    engineUsed: Self.engineUsedLabel(
                        engine: SettingsStore.shared.engine,
                        modelName: SettingsStore.shared.modelName),
                    mode: .streaming, status: .cancelled, errorMessage: nil, audioFilename: nil))
            HistoryStore.shared.persistAudio(id: entryID, samples: samples)
        }
        state = .idle
        hud.showMessage("Cancelled", autoHideAfter: 1.5)
    }

    // ------------------------------------------------------------------
    // Batch flow
    // ------------------------------------------------------------------

    private func beginBatchRecording() {
        do {
            try recorder.start()
            state = .recording
            SoundCues.play(.recordingStarted)
            recordingStartedAt = Date()
            // "Warming up…" until the mic delivers its first buffer;
            // startLevelTask() flips it to "Listening" then.
            hud.show(.warmingUp)
            startLevelTask()
        } catch {
            log.error("Recorder failed to start: \(error.localizedDescription, privacy: .public)")
            state = .error("Could not start microphone: \(error.localizedDescription)")
            hud.showMessage(
                HUDErrorText.message(for: error) ?? "Could not start the microphone. Try again.",
                autoHideAfter: 4)
        }
    }

    private func finishBatchRecording() async {
        levelTask?.cancel()
        levelTask = nil
        let heldFor = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        let samples = recorder.stop()
        let seconds = Double(samples.count) / 16_000.0
        log.info(
            "Batch recording finished: \(samples.count, privacy: .public) samples (\(String(format: "%.2f", seconds), privacy: .public)s)"
        )
        guard samples.count >= Self.minKeepSamples else {
            // Distinguish a wake-up failure - the key was held for a real moment
            // but the mic delivered almost nothing because it was still powering
            // up - from a quick accidental tap. The former gets an honest
            // message and a fresh device next time, not a silent discard.
            if heldFor >= 1.0, samples.count < 16_000 / 5 {
                let btHint =
                    AudioRecorder.defaultInputIsBluetooth()
                    ? " Bluetooth mics wake slowly; the built-in mic starts instantly."
                    : ""
                log.info(
                    "Batch recording captured almost no audio over \(String(format: "%.2f", heldFor), privacy: .public)s - likely mic wake-up."
                )
                hud.showMessage(
                    "The microphone was still waking up. Try again." + btHint,
                    autoHideAfter: 3
                )
                recorder.invalidate()
            } else {
                log.info("Batch recording too short (<400 ms), discarding.")
                hud.hide()
            }
            state = .idle
            return
        }
        // History entry BEFORE transcription: if the engine crashes or the
        // app dies mid-transcribe, the entry (and its WAV, written in the
        // background) is already on disk and shows up as Interrupted with a
        // Retry button on next launch.
        let entryID = UUID()
        HistoryStore.shared.add(
            DictationEntry(
                id: entryID, date: Date(), duration: seconds,
                rawText: nil, processedText: nil,
                engineUsed: Self.engineUsedLabel(
                    engine: SettingsStore.shared.engine, modelName: SettingsStore.shared.modelName),
                mode: .batch, status: .interrupted, errorMessage: nil, audioFilename: nil))
        HistoryStore.shared.persistAudio(id: entryID, samples: samples)
        state = .transcribing
        // A cold engine loads and ANE-compiles the model inside transcribe(),
        // which can take minutes on a first run. Show "Warming up…" for that
        // instead of a misleading "Transcribing"; an already-warm engine goes
        // straight to "Transcribing".
        let needsWarmup = !(await engine.isWarm())
        hud.show(needsWarmup ? .warmingUp : .transcribing)

        // DC-removal + peak-normalise to a sane level before handing off to
        // the engine. Parakeet TDT is trained on broadcast-loud speech and
        // hallucinates whole utterances on too-quiet input ("How are you
        // doing?" decoding to "What were you giving?" is the classic
        // signature). Log the original peak so follow-up support requests
        // have the numbers we need to diagnose mic gain issues.
        let prepared = AudioPreprocessor.normalize(samples)
        log.info(
            "Audio peak before normalisation: \(String(format: "%.1f", prepared.originalPeakDbFS), privacy: .public) dBFS"
        )
        let micWasVeryQuiet = prepared.originalPeakDbFS < -45

        do {
            if needsWarmup {
                await engine.warmup()
                hud.show(.transcribing)
            }
            let raw = try await engine.transcribe(samples: prepared.samples)
            let processed = makePostProcessor().apply(raw)
            // Optional LLM pass, after the deterministic pipeline ("scratch
            // that" and dropPreviousChunks are already resolved) and before
            // any insertion. polish() returns the input untouched when the
            // level is Off, the model is missing, or generation fails/times
            // out - the dictation always ships.
            var finalText = processed.text
            if !finalText.isEmpty, SettingsStore.shared.llmPostProcessLevel != .off {
                hud.show(.polishing)
                finalText = await LLMPostProcessor.polish(finalText)
            }
            if finalText.isEmpty {
                state = .idle
                if processed.dropPreviousChunks > 0 {
                    hud.showMessage("Nothing to scratch here", autoHideAfter: 2.5)
                } else {
                    hud.hide()
                }
            } else if SettingsStore.shared.autoPaste {
                inserter.insert(finalText + " ")
                state = .idle
                if micWasVeryQuiet {
                    hud.showMessage(
                        "Microphone level is very low. Speak louder or raise the input volume in System Settings → Sound.",
                        autoHideAfter: 2.5
                    )
                } else {
                    hud.hide()
                }
            } else {
                copyToClipboard(finalText)
                state = .idle
                hud.flashCopied()
            }
            // The history save is synchronous on the main actor - do it after
            // the text has landed, not before; a crash in between just leaves
            // a retryable .interrupted entry.
            HistoryStore.shared.update(entryID) {
                $0.rawText = raw
                $0.processedText = finalText
                $0.status = .ok
            }
        } catch {
            log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            HistoryStore.shared.update(entryID) {
                $0.status = .failed
                $0.errorMessage = error.localizedDescription
            }
            await reportError(error)
        }
    }

    // ------------------------------------------------------------------
    // Streaming flow
    // ------------------------------------------------------------------

    private func beginStreamingRecording() {
        streamingStartupInFlight = true
        releasedDuringStartup = false
        streamingCancelledByUser = false
        Task {
            do {
                let session = try await engine.makeStreamingSession()

                // Hotkey was released while we were loading the session.
                // Tear it down without ever entering recording state - the
                // user has already moved on.
                if releasedDuringStartup {
                    await session.cancel()
                    streamingStartupInFlight = false
                    state = .idle
                    hud.hide()
                    return
                }

                self.streamingSession = session

                do {
                    try recorder.start()
                } catch {
                    // Mic device disappeared / permission revoked. Cancel
                    // the session we just allocated so the next press isn't
                    // routed into a half-built streaming flow.
                    await session.cancel()
                    self.streamingSession = nil
                    streamingStartupInFlight = false
                    await reportError(error)
                    return
                }

                state = .recording
                SoundCues.play(.recordingStarted)
                recordingStartedAt = Date()
                // Reserve the pill's preview area before the first mic buffer
                // flips it to .recording, so it sizes once and shows the live
                // sentence as it streams.
                hud.setPreviewActive(true)
                hud.show(.warmingUp)
                startLevelTask()
                streamingStartupInFlight = false

                // Two concurrent tasks: feed chunks into the session, and
                // drain its events (preview + per-sentence commit). Both die
                // when the session is finished or cancelled.
                //
                // The feed task is owned by the coordinator (not nested inside
                // the event task) so finishStreamingRecording() can await it -
                // draining every buffered chunk into the session - before
                // calling finish(). finish() only transcribes audio already
                // fed, so a chunk still in flight when it runs would be lost:
                // that's the trailing words that vanish on a quick key release.
                feedTask = Task { [recorder, weak self] in
                    for await chunk in recorder.chunks {
                        guard self != nil else { break }
                        try? await session.feed(samples: chunk)
                    }
                }
                streamingTask = Task { [weak self] in
                    await self?.runStreamingTask(session: session) ?? ("", "")
                }
            } catch let EngineError.streamingNotSupported(name) {
                log.error("Streaming not supported by \(name, privacy: .public) - falling back to batch.")
                self.streamingSession = nil
                streamingStartupInFlight = false
                beginBatchRecording()
            } catch {
                self.streamingSession = nil
                streamingStartupInFlight = false
                await reportError(error)
            }
        }
    }

    private func runStreamingTask(session: any StreamingSession) async -> (
        raw: String, processed: String
    ) {
        // Per-sentence commit. Partials only drive the HUD preview - nothing
        // touches the document until a pause (EOU), when we post-process that
        // one sentence and paste it once. Already-committed text is never
        // re-edited, so there is no reconcile, no model drift, and no cascade
        // across pauses.
        //
        // The session resets the recognizer at each EOU, so every
        // `.endOfUtterance` carries one complete sentence (not the running
        // transcript). `committed` holds the exact strings pasted so "scratch
        // that" can delete them precisely.
        var committed: [String] = []
        var rawParts: [String] = []
        var preview = ""

        for await event in session.events {
            switch event {
            case .partial(let suffix):
                preview += suffix
                hud.updatePreview(preview)
            case .endOfUtterance(let utteranceRaw):
                // rawParts is the unedited ASR stream - "scratch that" trims
                // committed (what was typed) but never the raw record, matching
                // batch where transcribe() output includes command phrases
                // verbatim.
                rawParts.append(utteranceRaw)

                // A buffered EOU can drain after Esc (the user's pre-cancel
                // silence is exactly what fires it) - record it in the raw
                // stream but never let it touch the document.
                guard !streamingCancelledByUser else { continue }

                preview = ""
                hud.updatePreview("")

                let result = makePostProcessor().apply(utteranceRaw)
                postLog.debug(
                    "EOU commit: '\(result.text, privacy: .public)' drop=\(result.dropPreviousChunks, privacy: .public)"
                )

                // "scratch that" resolves to empty text + a drop signal: delete
                // exactly the characters we pasted for the last sentence(s).
                if result.dropPreviousChunks > 0 {
                    let drop = min(result.dropPreviousChunks, committed.count)
                    let chars = committed.suffix(drop).reduce(0) { $0 + $1.count }
                    committed.removeLast(drop)
                    if chars > 0 { inserter.deleteBackward(chars) }
                }

                guard !result.text.isEmpty else { continue }
                // One space between sentences, but only when neither side already
                // carries a break (a "new line" command, or a leading space the
                // PostProcessor already trimmed).
                let prevNeedsGap = committed.last?.last.map { !$0.isWhitespace } ?? false
                let nextNeedsGap = result.text.first.map { !$0.isWhitespace } ?? true
                let piece = (prevNeedsGap && nextNeedsGap ? " " : "") + result.text
                inserter.insert(piece)
                committed.append(piece)
            }
        }
        hud.updatePreview("")

        // Separate dictation sessions so the next press doesn't butt up
        // ("worldfoo"): one trailing space, unless the last sentence already
        // ended in whitespace (e.g. a "new line" command).
        //
        // Skip the session-separator space when the user cancelled - "no
        // further insertion" is the whole point of Esc.
        if !streamingCancelledByUser, let last = committed.last?.last, !last.isWhitespace {
            inserter.insert(" ")
        }

        return (rawParts.joined(separator: " "), committed.joined())
    }

    private func finishStreamingRecording() async {
        levelTask?.cancel()
        levelTask = nil
        let samples = recorder.stop()
        let seconds = Double(samples.count) / 16_000.0
        // Same short-tap threshold as batch: sub-400ms holds don't clutter
        // the history.
        var entryID: UUID?
        if samples.count >= Self.minKeepSamples {
            let id = UUID()
            entryID = id
            HistoryStore.shared.add(
                DictationEntry(
                    id: id, date: Date(), duration: seconds,
                    rawText: nil, processedText: nil,
                    engineUsed: Self.engineUsedLabel(
                        engine: SettingsStore.shared.engine, modelName: SettingsStore.shared.modelName),
                    mode: .streaming, status: .interrupted, errorMessage: nil, audioFilename: nil))
            HistoryStore.shared.persistAudio(id: id, samples: samples)
        }
        hud.setPreviewActive(false)
        state = .transcribing
        hud.show(.transcribing)

        guard let session = streamingSession else {
            state = .idle
            hud.hide()
            return
        }
        do {
            // recorder.stop() closed recorder.chunks, so the feed loop now
            // drains the last buffered mic chunks into the session and ends.
            // Await it BEFORE finish(): the manager only transcribes audio that
            // has already been fed, so finishing while chunks are still in
            // flight drops the trailing words - the ones still showing as a
            // live preview because no in-stream EOU (1.28 s of silence) had
            // fired yet. Bounded: the stream is closed, so the loop ends once
            // the buffered chunks are consumed.
            await feedTask?.value
            feedTask = nil

            // finish() flushes the remaining padded chunk, yields a final
            // .endOfUtterance, and closes the events stream; the
            // runStreamingTask loop commits that trailing utterance there.
            // Awaiting the task (rather than cancelling it) guarantees that
            // commit - and the trailing space appended after the loop - have
            // run before we tear down. The await is bounded: finish() already
            // closed the stream, so the loop terminates.
            try await session.finish()
            let texts = await streamingTask?.value
            if let entryID, let texts {
                HistoryStore.shared.update(entryID) {
                    $0.rawText = texts.raw
                    $0.processedText = texts.processed
                    $0.status = .ok
                }
            }
            streamingSession = nil
            streamingTask = nil
            state = .idle
            hud.hide()
        } catch {
            // finish() threw before closing the stream. Close it explicitly so
            // the consumer loop terminates, then drain both tasks (now bounded)
            // instead of leaking them.
            await session.cancel()
            let texts = await streamingTask?.value
            if let entryID {
                HistoryStore.shared.update(entryID) {
                    if let texts, !texts.raw.isEmpty { $0.rawText = texts.raw }
                    if let texts, !texts.processed.isEmpty { $0.processedText = texts.processed }
                    $0.status = .failed
                    $0.errorMessage = error.localizedDescription
                }
            }
            feedTask?.cancel()
            feedTask = nil
            streamingSession = nil
            streamingTask = nil
            await reportError(error)
        }
    }

    // ------------------------------------------------------------------
    // Shared helpers
    // ------------------------------------------------------------------

    private func startLevelTask() {
        levelTask = Task { [weak self] in
            guard let self else { return }
            var sawFirstBuffer = false
            // The first mic buffer flips the HUD from "Warming up…" to
            // "Listening"; every buffer after drives the live waveform.
            for await level in self.recorder.levels {
                if Task.isCancelled { break }
                if !sawFirstBuffer {
                    sawFirstBuffer = true
                    self.hud.show(.recording)
                }
                self.hud.updateLevel(level)
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func makePostProcessor() -> PostProcessor {
        PostProcessor(
            trimFillers: SettingsStore.shared.trimFillers,
            customFillerWords: SettingsStore.shared.customFillerWords,
            voiceCommandsEnabled: SettingsStore.shared.voiceCommands,
            customVoiceCommands: SettingsStore.shared.customVoiceCommands,
            dictionary: SettingsStore.shared.dictionary
        )
    }

    // Re-runs transcription + post-processing over a history entry's saved
    // WAV, now via the background queue: retries serialize with meetings and
    // drops, so two Whisper pipes never load at once. beginRetry() survives
    // purely as a double-enqueue guard; the queue calls endRetry() when the
    // job finishes (see TranscriptionQueue.processFile).
    func retryHistoryEntry(_ id: UUID, using choice: SettingsStore.Engine) async {
        guard let entry = HistoryStore.shared.entries.first(where: { $0.id == id }),
            HistoryStore.shared.audioURL(for: entry) != nil
        else { return }
        guard HistoryStore.shared.beginRetry(id) else { return }
        do {
            try TranscriptionQueue.shared.enqueueFile(
                jobID: UUID(), entryID: id,
                sourceFilename: entry.sourceFilename ?? "dictation",
                duration: entry.duration,
                engine: choice, whisperModel: SettingsStore.shared.modelName,
                isRetry: true)
        } catch {
            log.error(
                "Retry enqueue failed: \(error.localizedDescription, privacy: .public)")
            HistoryStore.shared.endRetry(id)
        }
    }

    // B1: audio files dropped on the History window. One .queued entry + one
    // queue job per file; decode runs off-main (a podcast-sized file takes a
    // moment). The engine is the MEETING engine at drop time — an external
    // audio is closer to a meeting than to a dictation, and Retry can rerun
    // it with any other engine.
    func importAudioFiles(_ urls: [URL]) async {
        let queue = TranscriptionQueue.shared
        for url in urls {
            let entryID = UUID()
            let jobID = UUID()
            let filename = url.lastPathComponent
            let engineChoice = SettingsStore.shared.meetingEngine
            let model = SettingsStore.shared.modelName
            do {
                let samples = try await Task.detached(priority: .utility) {
                    try AudioFileDecoder.decode16kMono(url: url)
                }.value
                let duration = TimeInterval(samples.count) / 16_000.0
                let jobDir = queue.jobDirectory(jobID)
                try await Task.detached(priority: .utility) {
                    try FileManager.default.createDirectory(
                        at: jobDir, withIntermediateDirectories: true)
                    try WAVFile.write(
                        samples: samples, to: jobDir.appendingPathComponent("audio.wav"))
                }.value
                HistoryStore.shared.add(
                    DictationEntry(
                        id: entryID, date: Date(), duration: duration, rawText: nil,
                        processedText: nil,
                        engineUsed: Self.engineUsedLabel(engine: engineChoice, modelName: model),
                        mode: .batch, status: .queued, errorMessage: nil, audioFilename: nil,
                        sourceFilename: filename))
                try queue.enqueueFile(
                    jobID: jobID, entryID: entryID, sourceFilename: filename,
                    duration: duration, engine: engineChoice, whisperModel: model,
                    isRetry: false)
            } catch {
                log.error(
                    "Audio import failed for \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                // A failed decode still leaves a visible, explainable row.
                HistoryStore.shared.add(
                    DictationEntry(
                        id: entryID, date: Date(), duration: 0, rawText: nil, processedText: nil,
                        engineUsed: Self.engineUsedLabel(engine: engineChoice, modelName: model),
                        mode: .batch, status: .failed, errorMessage: error.localizedDescription,
                        audioFilename: nil, sourceFilename: filename))
            }
        }
    }

    // Spec format for DictationEntry.engineUsed: stable machine-ish strings,
    // rendered human-friendly by HistoryView.
    nonisolated static func engineUsedLabel(
        engine: SettingsStore.Engine, modelName: String
    ) -> String {
        switch engine {
        case .parakeet: return "parakeet"
        case .parakeetV3: return "parakeet-v3"
        case .nemotron: return "nemotron"
        case .whisper: return "whisper:\(modelName)"
        }
    }

    private func reportError(_ error: Error) async {
        // Full technical detail (codes, selectors) stays in the log; the HUD
        // gets a short user-facing message, or "Try again" when the cause is
        // unknown. Unknown errors clear quickly; specific guidance lingers
        // long enough to read.
        log.error("Dictation error: \(error.localizedDescription, privacy: .public)")
        state = .error(error.localizedDescription)
        let mapped = HUDErrorText.message(for: error)
        let duration: TimeInterval = mapped == nil ? 2 : 4
        hud.showMessage(mapped ?? "Try again", autoHideAfter: duration)
        try? await Task.sleep(for: .seconds(duration))
        if case .error = state {
            state = .idle
        }
    }
}
