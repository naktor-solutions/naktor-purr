import Accelerate
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os.log

// Captures system audio output - everything other apps are playing, i.e. the
// remote participants on a meeting call - and yields a Float32 / 16 kHz / mono
// PCM array, the same shape AudioRecorder produces for the microphone.
//
// macOS forbids an AVAudioEngine input node from seeing other apps' audio, so
// this uses Core Audio process taps (macOS 14.2+):
//
//   1. A CATapDescription for a mono mixdown of every process except our own.
//   2. AudioHardwareCreateProcessTap turns that into a tap object.
//   3. A private aggregate device wraps the default output device plus the
//      tap, so an AudioDeviceIOProc delivers the tapped audio.
//   4. The IO callback resamples the tap format (commonly 48 kHz) down to
//      16 kHz mono and appends into a growing buffer.
//
// The tap is `.unmuted`, so the user still hears their call normally. macOS
// prompts once for "System Audio Recording" permission on the first start;
// if denied the capture simply yields silence and the meeting falls back to
// a microphone-only transcript.
@available(macOS 14.2, *)
final class SystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat
    // The tap delivers samples only while system audio is actually playing, so
    // a flat concatenation collapses the silent gaps. Keep each delivered chunk
    // with the host time it was captured at so stop() can rebuild a continuous,
    // mic-aligned buffer. Guarded by `lock`.
    private var capturedChunks: [(host: UInt64, data: [Float])] = []
    private let lock = NSLock()
    // Live RMS of the tapped audio, mirrored to the meeting HUD's waveform so it
    // reacts to system / remote sound and not just the mic. Yielded from the IO
    // callback; the consumer blends it with the mic level. Like the captured
    // chunks, this goes quiet when nothing plays (the tap delivers no buffers
    // during silence), so the consumer decays it back to rest.
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private(set) var levels: AsyncStream<Float> = AsyncStream { _ in }
    private let queue = DispatchQueue(
        label: "com.naktor.barktor.systemaudio", qos: .userInitiated)
    private let log = Logger(subsystem: "com.naktor.barktor", category: "systemaudio")

    // Peak magnitude below this (~-60 dBFS) means the tap delivered effectively
    // only silence. The usual cause is a denied "System Audio Recording"
    // permission: macOS still creates the tap and runs its IOProc, it just
    // zero-fills every buffer while the output device is active (e.g. a video is
    // playing). Such a buffer has nothing to transcribe or diarize, so we treat
    // it as "no system audio" and let the meeting fall back to the mic.
    private static let silenceFloor: Float = 0.001

    // Set by stop(): true when the tap delivered a substantial buffer that was
    // effectively silent - the signature of an active output device with the
    // System Audio Recording permission denied. Read once after stop() so the
    // meeting can tell the user why remote voices weren't captured.
    private(set) var lastCaptureSilentButActive = false

    init() {
        // 16 kHz mono Float32 - the shape every ASR path in the app consumes.
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        else {
            fatalError("Could not construct 16kHz mono Float32 audio format")
        }
        self.targetFormat = format
    }

    // Public entry point. Wraps the actual start sequence in a catch that
    // self-cleans on failure: a process tap, aggregate device, or IOProc
    // allocated before a later step threw is a system-level audio object
    // that would otherwise leak until the process exits (Swift's ARC only
    // reclaims the wrapper, not the C-side registration). Routing the
    // cleanup through stop() keeps all teardown in one place.
    func start() throws {
        do {
            try startInternal()
        } catch {
            _ = stop(alignedTo: 0)
            throw error
        }
    }

    private func startInternal() throws {
        lock.lock()
        capturedChunks.removeAll(keepingCapacity: true)
        lock.unlock()

        // Fresh level stream per capture; stop() finishes it. Set up before the
        // IO proc starts so no early callback yields into a dead continuation.
        levels = AsyncStream { continuation in
            self.levelContinuation = continuation
        }

        // Tap every process except ourselves, mixed down to mono. Excluding
        // our own process keeps Barktor's own sounds out of the capture;
        // if our process object isn't resolvable yet we just tap everything.
        let excluded = ownProcessObject().map { [$0] } ?? []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Barktor Meeting Tap"
        description.isPrivate = true
        // Unmuted: the user must keep hearing their meeting normally.
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &newTapID)
        guard err == noErr, newTapID != AudioObjectID(kAudioObjectUnknown) else {
            throw SystemAudioError.tapCreationFailed(err)
        }
        tapID = newTapID

        let asbd = try tapStreamDescription(tapID)
        var mutableASBD = asbd
        guard let format = AVAudioFormat(streamDescription: &mutableASBD) else {
            throw SystemAudioError.unsupportedTapFormat
        }
        tapFormat = format
        converter = AVAudioConverter(from: format, to: targetFormat)
        guard converter != nil else {
            throw SystemAudioError.unsupportedTapFormat
        }

        // A private aggregate device wrapping the default output device and
        // the tap. Private keeps it out of the system-wide device list.
        let outputDevice = try defaultOutputDevice()
        let outputUID = try deviceUID(outputDevice)
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Barktor Meeting Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregateID)
        guard err == noErr, newAggregateID != AudioObjectID(kAudioObjectUnknown) else {
            throw SystemAudioError.aggregateCreationFailed(err)
        }
        aggregateID = newAggregateID

        var newProcID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, queue) {
            [weak self] _, inputData, inputTime, _, _ in
            self?.handle(inputData, at: inputTime)
        }
        guard err == noErr, let newProcID else {
            throw SystemAudioError.ioProcCreationFailed(err)
        }
        procID = newProcID

        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else {
            throw SystemAudioError.deviceStartFailed(err)
        }

        log.info("System audio capture started - tap format \(String(describing: format), privacy: .public)")
    }

    // Stops capture, tears down the Core Audio objects, and returns whatever
    // 16 kHz mono audio was captured. Safe to call even if start() failed
    // partway - each teardown step is guarded.
    func stop(alignedTo micStartHostTime: UInt64) -> [Float] {
        if aggregateID != AudioObjectID(kAudioObjectUnknown), let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        converter = nil
        tapFormat = nil

        levelContinuation?.finish()
        levelContinuation = nil

        lock.lock()
        let chunks = capturedChunks
        capturedChunks.removeAll(keepingCapacity: false)
        lock.unlock()

        let rawCount = chunks.reduce(0) { $0 + $1.data.count }
        // Rebuild a continuous buffer whose index 0 lines up with the mic's
        // first sample, with silence restored where the tap delivered nothing.
        let aligned = Self.reconstruct(chunks: chunks, micStartHostTime: micStartHostTime)

        // Distinguish a real capture from a permission-denied silent one: a
        // denied tap returns *non-empty* buffers of zeros whenever the output
        // device was active, which would otherwise push the meeting into the
        // dual-track path and make the diarizer choke on silence. Measure the
        // level and return empty for an effectively-silent capture so the
        // caller's `isEmpty` check routes it to the mic-only path. Use the raw
        // sample count for the "active" test so reconstructed leading silence
        // can't inflate it.
        var peak: Float = 0
        if !aligned.isEmpty {
            vDSP_maxmgv(aligned, 1, &peak, vDSP_Length(aligned.count))
        }
        let peakDB = peak > 0 ? 20 * log10(peak) : -120
        let silent = peak < Self.silenceFloor
        let rawSeconds = Double(rawCount) / 16_000.0
        let alignedSeconds = Double(aligned.count) / 16_000.0
        log.info(
            "System audio capture stopped - raw \(rawCount, privacy: .public) samples (~\(String(format: "%.2f", rawSeconds), privacy: .public)s), aligned \(aligned.count, privacy: .public) (~\(String(format: "%.2f", alignedSeconds), privacy: .public)s), peak \(String(format: "%.4f", peak), privacy: .public) (\(String(format: "%.1f", peakDB), privacy: .public) dBFS)\(silent ? " - silent, treating as no system audio" : "", privacy: .public)"
        )
        lastCaptureSilentButActive = silent && rawCount >= 16_000
        return silent ? [] : aligned
    }

    // Rebuilds a continuous, mic-aligned 16 kHz buffer from the tap's chunks.
    // Each chunk is placed at (chunkHost - micStartHost) seconds and the gaps
    // are zero-filled, restoring a true timeline that lines up with the mic
    // track index-for-index - so cross-track merging sorts correctly, the
    // diarizer sees real pauses, and echo cancellation gets a time-aligned
    // reference. Without a mic reference it aligns on the first chunk (interior
    // gaps still restored, no leading pad).
    private static func reconstruct(
        chunks: [(host: UInt64, data: [Float])],
        micStartHostTime: UInt64
    ) -> [Float] {
        guard !chunks.isEmpty else { return [] }
        let reference = micStartHostTime != 0 ? micStartHostTime : chunks[0].host

        var positions = [Int](repeating: 0, count: chunks.count)
        var total = 0
        for (i, chunk) in chunks.enumerated() {
            let deltaTicks = chunk.host > reference ? chunk.host - reference : 0
            let offsetSeconds = Double(AudioConvertHostTimeToNanos(deltaTicks)) / 1_000_000_000.0
            let pos = max(0, Int((offsetSeconds * 16_000.0).rounded()))
            positions[i] = pos
            total = max(total, pos + chunk.data.count)
        }

        var output = [Float](repeating: 0, count: total)
        output.withUnsafeMutableBufferPointer { out in
            guard let base = out.baseAddress else { return }
            for (i, chunk) in chunks.enumerated() {
                let pos = positions[i]
                let n = min(chunk.data.count, total - pos)
                guard n > 0 else { continue }
                chunk.data.withUnsafeBufferPointer { src in
                    guard let srcBase = src.baseAddress else { return }
                    base.advanced(by: pos).update(from: srcBase, count: n)
                }
            }
        }
        return output
    }

    // ------------------------------------------------------------------
    // IO callback
    // ------------------------------------------------------------------

    private func handle(
        _ inputData: UnsafePointer<AudioBufferList>,
        at inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        guard let tapFormat, let converter else { return }
        guard
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: tapFormat, bufferListNoCopy: inputData, deallocator: nil)
        else { return }

        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 16)
        guard capacity > 0,
            let outBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: capacity)
        else { return }

        var error: NSError?
        var providedInput = false
        let status = converter.convert(to: outBuffer, error: &error) { _, statusPtr in
            if providedInput {
                statusPtr.pointee = .noDataNow
                return nil
            }
            providedInput = true
            statusPtr.pointee = .haveData
            return inputBuffer
        }
        if status == .error {
            log.error(
                "System audio converter error: \(error?.localizedDescription ?? "unknown", privacy: .public)"
            )
            return
        }

        guard let channelData = outBuffer.floatChannelData?[0] else { return }
        let frameCount = Int(outBuffer.frameLength)
        if frameCount == 0 { return }
        let chunk = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        // Host time of this buffer, on the same mach clock as the mic's AUHAL
        // timestamp, so stop() can place the chunk at its true offset.
        let stamp = inputTime.pointee
        let host =
            stamp.mFlags.contains(.hostTimeValid) && stamp.mHostTime != 0
            ? stamp.mHostTime : mach_absolute_time()
        lock.lock()
        capturedChunks.append((host: host, data: chunk))
        lock.unlock()

        // Mirror this block's RMS to the meeting HUD's waveform (visualization
        // only; the captured chunks above are untouched). The tap delivers no
        // buffers during silence, so the consumer decays this back to rest.
        var rms: Float = 0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameCount))
        levelContinuation?.yield(rms)
    }

    // ------------------------------------------------------------------
    // Core Audio property helpers
    // ------------------------------------------------------------------

    // The audio process object for our own PID, used to exclude Barktor's
    // own sounds from the tap. Returns nil if the process hasn't registered
    // with the audio system yet (it never output audio) - harmless, we just
    // don't exclude ourselves.
    private func ownProcessObject() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var result = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafeMutablePointer(to: &pid) { pidPtr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &result)
        }
        return err == noErr && result != AudioObjectID(kAudioObjectUnknown) ? result : nil
    }

    private func defaultOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard err == noErr, device != AudioObjectID(kAudioObjectUnknown) else {
            throw SystemAudioError.noDefaultOutputDevice(err)
        }
        return device
    }

    private func deviceUID(_ device: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, ptr)
        }
        guard err == noErr else { throw SystemAudioError.deviceUIDUnavailable(err) }
        return uid as String
    }

    private func tapStreamDescription(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = withUnsafeMutablePointer(to: &asbd) { ptr in
            AudioObjectGetPropertyData(tap, &address, 0, nil, &size, ptr)
        }
        guard err == noErr else { throw SystemAudioError.unsupportedTapFormat }
        return asbd
    }
}

enum SystemAudioError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case noDefaultOutputDevice(OSStatus)
    case deviceUIDUnavailable(OSStatus)
    case unsupportedTapFormat

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let status):
            return "Could not create the system-audio tap (status \(status))."
        case .aggregateCreationFailed(let status):
            return "Could not create the system-audio aggregate device (status \(status))."
        case .ioProcCreationFailed(let status):
            return "Could not start the system-audio capture callback (status \(status))."
        case .deviceStartFailed(let status):
            return "Could not start system-audio capture (status \(status))."
        case .noDefaultOutputDevice(let status):
            return "No default audio output device is available (status \(status))."
        case .deviceUIDUnavailable(let status):
            return "Could not read the output device identifier (status \(status))."
        case .unsupportedTapFormat:
            return "The system-audio tap returned an unsupported audio format."
        }
    }
}
