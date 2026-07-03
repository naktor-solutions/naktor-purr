import AppKit

// Subtle audible confirmation for dictation lifecycle events. System sounds
// only (no bundled assets), quiet enough to sit under any playing audio.
// Gated by SettingsStore.soundCues; cancellation gets a distinct cue so a
// discarded dictation never sounds like a successful stop.
@MainActor
enum SoundCues {
    enum Cue {
        case recordingStarted
        case recordingStopped
        case dictationCancelled
    }

    static func play(_ cue: Cue) {
        guard SettingsStore.shared.soundCues else { return }
        let name: String
        switch cue {
        case .recordingStarted: name = "Tink"
        case .recordingStopped: name = "Pop"
        case .dictationCancelled: name = "Basso"
        }
        // copy() so rapid start/stop can overlap instead of cutting off.
        guard let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = 0.25
        sound.play()
    }
}
