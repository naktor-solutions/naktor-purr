import FluidAudio
import Foundation
import os.log

// Merges an engine-agnostic DetailedTranscription with a list of
// TimedSpeakerSegment into a readable Markdown transcript with
// `**Speaker N:** ...` blocks.
//
// Merge strategy: each token's midpoint chooses a speaker. Consecutive
// same-speaker tokens get concatenated verbatim - Parakeet's BPE tokens and
// Whisper's word timings both already carry leading spaces on word
// boundaries, so inserting our own spaces breaks subwords ("H" + "ello" ->
// "H ello"). TranscriptCleaner trims any leading whitespace at utterance
// boundaries. We rewrite FluidAudio's stable speaker IDs ("speaker_0001") to
// display labels ("Speaker 1") in the order they first speak.
enum MeetingDocument {
    private static let log = Logger(subsystem: "com.naktor.purr", category: "meetingdoc")

    struct Output {
        let markdown: String
        let recordedAt: Date
    }

    // Mic-only variant. The microphone is the local user, so every utterance
    // is labelled "You" (source beats voice) - no diarization runs on the mic
    // track. A single voice never becomes "Speaker 1", and a short/quiet solo
    // clip can't be rejected by the diarizer.
    static func format(
        localOnly asr: DetailedTranscription,
        duration: TimeInterval,
        recordedAt: Date,
        engineLabel: String
    ) -> Output {
        let utterances = localUtterances(asr: asr)

        var body = ""
        body += "# Meeting - \(formatTimestamp(recordedAt))\n\n"
        body += "_Duration: \(formatDuration(duration))_  "
        body += "_Speakers: \(utterances.isEmpty ? 0 : 1)_  "
        body += "_Engine: \(engineLabel)_\n\n"
        body += "---\n\n"

        if utterances.isEmpty {
            // No usable token timings (rare) - fall back to the raw transcript
            // so the user doesn't lose the audio they just recorded.
            let cleaned = TranscriptCleaner.clean(asr.text)
            body += cleaned.isEmpty ? "_No speech detected._" : cleaned
            body += "\n"
            return Output(markdown: body, recordedAt: recordedAt)
        }

        for utt in utterances {
            let cleaned = TranscriptCleaner.clean(utt.text)
            guard !cleaned.isEmpty else { continue }
            body += "**\(utt.speaker):** \(cleaned)\n\n"
        }

        return Output(markdown: body, recordedAt: recordedAt)
    }

    // Dual-track variant for meeting mode with system-audio capture. The
    // remote track (system audio) is diarized into Speaker N; the local track
    // (echo-cancelled microphone) is the single local user, labelled You.
    static func format(
        localASR: DetailedTranscription,
        remoteASR: DetailedTranscription,
        remoteSegments: [TimedSpeakerSegment],
        duration: TimeInterval,
        recordedAt: Date,
        engineLabel: String
    ) -> Output {
        let labelMap = buildLabelMap(segments: remoteSegments)
        var utterances = remoteUtterances(
            asr: remoteASR, segments: remoteSegments, labelMap: labelMap)
        // localUtterances() returns [] whenever localASR has no token timings -
        // that's true both for genuine silence AND for a Whisper model with no
        // alignment head, which can return real text with zero word timings.
        // Only treat it as silence when the (cleaned) raw text is also empty;
        // otherwise fall back to one unattributed "You" utterance so the
        // user's side of the meeting isn't silently dropped.
        let local = localUtterances(asr: localASR)
        utterances += local.isEmpty ? rawUtterance(asr: localASR, speaker: "You") : local
        utterances.sort(by: { $0.startTime < $1.startTime })

        let speakerCount = Set(utterances.map(\.speaker)).count

        var body = ""
        body += "# Meeting - \(formatTimestamp(recordedAt))\n\n"
        body += "_Duration: \(formatDuration(duration))_  "
        body += "_Speakers: \(speakerCount)_  "
        body += "_Engine: \(engineLabel) + FluidAudio Diarizer_\n\n"
        body += "---\n\n"

        if utterances.isEmpty {
            // Neither track produced speech - fall back to the raw text so a
            // recording is never silently lost.
            let cleaned = TranscriptCleaner.clean(
                (localASR.text + " " + remoteASR.text).trimmingCharacters(in: .whitespaces))
            body += cleaned.isEmpty ? "_No speech detected._" : cleaned
            body += "\n"
            return Output(markdown: body, recordedAt: recordedAt)
        }

        for utt in utterances {
            let cleaned = TranscriptCleaner.clean(utt.text)
            guard !cleaned.isEmpty else { continue }
            body += "**\(utt.speaker):** \(cleaned)\n\n"
        }
        return Output(markdown: body, recordedAt: recordedAt)
    }

    // ------------------------------------------------------------------
    // Dual-track utterance merge
    // ------------------------------------------------------------------

    // A speaker turn with a start time, used to interleave the local and
    // remote tracks chronologically. `endTime` drives the silence-gap split.
    private struct TimedUtterance {
        var speaker: String
        var text: String
        var startTime: Double
        var endTime: Double
    }

    // A pause longer than this between two tokens ends the current utterance
    // and starts a new one, so a long monologue still interleaves naturally
    // with the other track.
    private static let utteranceGapSeconds: Double = 1.0
    private static let remoteFallbackSpeaker = "Remote"

    private static func remoteUtterances(
        asr: DetailedTranscription,
        segments: [TimedSpeakerSegment],
        labelMap: [String: String]
    ) -> [TimedUtterance] {
        let timings = asr.tokens
        guard !timings.isEmpty else {
            return rawUtterance(asr: asr, speaker: remoteFallbackSpeaker)
        }
        guard !segments.isEmpty else {
            var result: [TimedUtterance] = []
            for timing in timings {
                let token = timing.text
                if token.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                appendToken(
                    token, speaker: remoteFallbackSpeaker, start: timing.start,
                    end: timing.end, into: &result)
            }
            return result.isEmpty
                ? rawUtterance(asr: asr, speaker: remoteFallbackSpeaker) : result
        }
        let sorted = segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds })

        var result: [TimedUtterance] = []
        for timing in timings {
            let token = timing.text
            if token.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let midpoint = (timing.start + timing.end) / 2.0
            let speakerId = speakerAt(time: midpoint, segments: sorted)
            let label = labelMap[speakerId] ?? speakerId
            appendToken(
                token, speaker: label, start: timing.start, end: timing.end,
                into: &result)
        }
        return result.isEmpty ? rawUtterance(asr: asr, speaker: remoteFallbackSpeaker) : result
    }

    private static func localUtterances(asr: DetailedTranscription) -> [TimedUtterance] {
        let timings = asr.tokens
        guard !timings.isEmpty else { return [] }
        var result: [TimedUtterance] = []
        for timing in timings {
            let token = timing.text
            if token.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            appendToken(
                token, speaker: "You", start: timing.start, end: timing.end,
                into: &result)
        }
        return result
    }

    private static func rawUtterance(asr: DetailedTranscription, speaker: String) -> [TimedUtterance] {
        let cleaned = TranscriptCleaner.clean(asr.text)
        guard !cleaned.isEmpty else { return [] }
        return [
            TimedUtterance(
                speaker: speaker,
                text: cleaned,
                startTime: 0,
                endTime: asr.duration
            )
        ]
    }

    private static func appendToken(
        _ token: String,
        speaker: String,
        start: Double,
        end: Double,
        into result: inout [TimedUtterance]
    ) {
        // Punctuation belongs to the word it follows. TDT often stamps a
        // sentence-final "." / "?" well after the word it closes - sometimes
        // past utteranceGapSeconds, sometimes into the next speaker's segment -
        // so trusting its timestamp strands it on its own line or at the head of
        // the next turn. Glue any punctuation-only token onto the current
        // utterance and leave that utterance's end time on the spoken word, so
        // the late mark can't distort the gap test for the tokens that follow.
        if isPunctuationOnly(token), !result.isEmpty {
            result[result.count - 1].text += token
            return
        }
        if var last = result.last, last.speaker == speaker,
            start - last.endTime <= utteranceGapSeconds
        {
            last.text += token
            last.endTime = end
            result[result.count - 1] = last
        } else {
            result.append(
                TimedUtterance(speaker: speaker, text: token, startTime: start, endTime: end))
        }
    }

    private static func isPunctuationOnly(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let marks = CharacterSet.punctuationCharacters.union(CharacterSet(charactersIn: "?!"))
        return trimmed.unicodeScalars.allSatisfy { marks.contains($0) }
    }

    static func write(_ output: Output) throws -> URL {
        let name = "Meeting \(filenameTimestamp(output.recordedAt)).md"
        let data = output.markdown.data(using: .utf8)!
        do {
            return try write(data, named: name, into: meetingsDirectory())
        } catch {
            // The configured folder was deleted or became unwritable between
            // setup and now. Rather than lose the transcript, fall back to the
            // default Application Support folder (no TCC consent needed, so this
            // write effectively always succeeds). If the configured folder *was*
            // the default, this is a harmless retry of the same path.
            let fallback = SettingsStore.defaultMeetingsDirectory
            // Only a *configured* folder failing is a surprising redirect worth
            // flagging; an empty preference means we were already targeting the
            // default, so a failure there is a plain error, not a fallback.
            if !SettingsStore.shared.meetingsFolderPath.isEmpty {
                log.warning(
                    "Meeting save to chosen folder failed (\(error.localizedDescription, privacy: .public)); saved to default folder \(fallback.path, privacy: .public) instead"
                )
            }
            return try write(data, named: name, into: fallback)
        }
    }

    private static func write(_ data: Data, named name: String, into dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    // Resolves the meeting save folder: the user-chosen folder when one is set,
    // otherwise the default Application Support folder. Selection happens in
    // onboarding; an empty preference means "use the default".
    static func meetingsDirectory() -> URL {
        let path = SettingsStore.shared.meetingsFolderPath
        if path.isEmpty {
            return SettingsStore.defaultMeetingsDirectory
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // ------------------------------------------------------------------
    // Label assignment
    // ------------------------------------------------------------------

    private static func buildLabelMap(segments: [TimedSpeakerSegment]) -> [String: String] {
        var map: [String: String] = [:]
        var counter = 1
        for seg in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            if map[seg.speakerId] == nil {
                map[seg.speakerId] = "Speaker \(counter)"
                counter += 1
            }
        }
        return map
    }

    // ------------------------------------------------------------------
    // Token / segment merge
    // ------------------------------------------------------------------

    private static func speakerAt(time: Double, segments: [TimedSpeakerSegment]) -> String {
        // First segment that contains the timestamp wins. If none does (the
        // diarizer is usually slightly tighter than the ASR), pick the
        // closest segment by midpoint distance - better than dropping the
        // word.
        for seg in segments {
            if Double(seg.startTimeSeconds) <= time, time <= Double(seg.endTimeSeconds) {
                return seg.speakerId
            }
        }
        var bestId = segments.first?.speakerId ?? "speaker_unknown"
        var bestDistance = Double.infinity
        for seg in segments {
            let mid = (Double(seg.startTimeSeconds) + Double(seg.endTimeSeconds)) / 2.0
            let d = abs(mid - time)
            if d < bestDistance {
                bestDistance = d
                bestId = seg.speakerId
            }
        }
        return bestId
    }

    // ------------------------------------------------------------------
    // Formatting helpers
    // ------------------------------------------------------------------

    private static func formatTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: date)
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
