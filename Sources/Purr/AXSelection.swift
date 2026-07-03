import ApplicationServices
import os.log

// Reads and writes the currently selected text in the focused UI element of
// the focused application via the Accessibility API. Powers the
// "select these words, then speak the edit" interaction.
//
// Coverage: native AppKit text fields, NSTextView, most Cocoa apps respect
// `kAXSelectedTextAttribute`. Notable holdouts: Chrome's web text fields,
// some Electron-rendered editors. For those we fall back to
// "select-then-paste-the-replacement" via TextInserter - since pasting
// always overwrites the selection, the user gets the right behaviour even
// if AX read of the selection failed (we treat the selection as empty and
// abort). When AX read succeeds but write doesn't, the same paste fallback
// kicks in.
enum AXSelection {
    enum Failure: LocalizedError {
        case axDenied
        case noFocusedElement
        case noSelection
        case unreadable

        var errorDescription: String? {
            switch self {
            case .axDenied:
                return
                    "Voice Edit needs Accessibility access to read selected text. Turn it on in System Settings → Privacy & Security → Accessibility."
            case .noFocusedElement: return "No text field is focused. Click into one and try again."
            case .noSelection: return "Select some text first, then hold the Voice Edit key."
            case .unreadable: return "This app doesn't share its text selection, so Voice Edit can't read it."
            }
        }
    }

    private static let log = Logger(subsystem: "com.naktor.purr", category: "ax")

    // Returns the currently selected string in the focused element, or
    // throws if no selection / AX denied / element doesn't expose it.
    static func readSelection() throws -> String {
        guard AXIsProcessTrusted() else { throw Failure.axDenied }

        let element = try focusedElement()
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        )
        guard status == .success else {
            log.debug("AX selection read failed with status \(status.rawValue, privacy: .public)")
            throw Failure.unreadable
        }
        guard let text = value as? String else { throw Failure.unreadable }
        if text.isEmpty { throw Failure.noSelection }
        return text
    }

    // Replaces the current selection with the given string. Returns true on
    // success; false if the focused element doesn't accept AX writes - the
    // caller should then fall back to a paste-overwrite.
    @discardableResult
    static func replaceSelection(with replacement: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let element = try? focusedElement() else { return false }

        let status = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            replacement as CFTypeRef
        )
        if status != .success {
            log.debug("AX selection write failed with status \(status.rawValue, privacy: .public)")
            return false
        }
        return true
    }

    // ------------------------------------------------------------------
    // System-wide focused element lookup
    // ------------------------------------------------------------------

    private static func focusedElement() throws -> AXUIElement {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard status == .success else { throw Failure.noFocusedElement }
        guard let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else {
            throw Failure.noFocusedElement
        }
        return element as! AXUIElement
    }
}
