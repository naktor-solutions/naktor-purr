import AVFoundation

// Turns a thrown error into a short, user-facing HUD message. Two rules the
// HUD depends on: no raw error codes (those stay in the log via the caller's
// log.error), and no em dashes. Returns nil when there's no specific guidance
// to offer, so callers fall back to the generic "Try again" pill.
//
// The phrasing follows the recoverable-vs-actionable split: a denied mic
// permission or a missing model tells the user what to *do* (retrying won't
// help), while genuinely unknown failures fall through to "Try again".
enum HUDErrorText {
    static func message(for error: Error) -> String? {
        // A revoked microphone permission is the most common non-retryable
        // cause, and it can mask itself as a generic capture failure. Check it
        // first so we never tell the user to "try again" when a retry cannot
        // succeed until they flip the System Settings toggle.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            return
                "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
        default:
            break
        }

        if let audio = error as? AudioError {
            switch audio {
            case .auhalSetup:
                return
                    "Could not start the microphone. Check it is connected and selected in System Settings → Sound."
            case .invalidInputFormat:
                return
                    "The microphone returned an unsupported format. Pick a different input in System Settings → Sound."
            case .cannotBuildConverter:
                return "Could not set up audio for this microphone. Try a different input device."
            }
        }

        // EngineError's descriptions are already written for users and carry
        // the right action (download a model, switch engine), with no codes or
        // em dashes, so surface them verbatim.
        if let engine = error as? EngineError {
            return engine.errorDescription
        }

        return nil
    }
}
