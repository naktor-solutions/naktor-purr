import AVFoundation
import AppKit
import ApplicationServices
import IOKit.hid

// Reads the three TCC states we depend on, and "asks" for the two we can
// actually request programmatically (Accessibility and Input Monitoring).
//
// Calling AXIsProcessTrustedWithOptions and IOHIDRequestAccess does two
// things macOS won't do for us automatically:
//   1. Registers the app in the System Settings list under the right pane.
//      Until the app calls these once, it won't appear in the list at all.
//   2. Shows the system prompt the FIRST time only. After deny/dismiss the
//      user has to manually toggle in System Settings, which is why "Grant"
//      always also opens the deeplinked pane as a fallback.
//
// After the bundle ID changes (e.g. from a rename) or after re-signing an
// ad-hoc-signed binary multiple times, prior grants can become stale -
// they're attached to a code signature designation that no longer matches
// the running app. The user has to remove the old entry from System
// Settings (or run `tccutil reset Accessibility com.naktor.purr`
// and `tccutil reset ListenEvent com.naktor.purr`) and grant
// again.
enum Permissions {
    enum Kind: String, CaseIterable, Identifiable {
        case microphone, accessibility, inputMonitoring
        var id: String { rawValue }

        var title: String {
            switch self {
            case .microphone: return "Microphone"
            case .accessibility: return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            }
        }
        var why: String {
            switch self {
            case .microphone:
                return "Purr needs access to record your voice."
            case .accessibility:
                return "Required so Purr can paste your transcript at the cursor."
            case .inputMonitoring:
                return "Required so Purr can listen for the global hotkey across every app."
            }
        }
        var settingsURL: URL {
            // x-apple.systempreferences URLs deeplink to the right pane in
            // System Settings. These work on macOS 13+; the IDs occasionally
            // change between macOS versions but these three have been stable
            // since Ventura.
            switch self {
            case .microphone:
                return URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .accessibility:
                return URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .inputMonitoring:
                return URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
            }
        }
    }

    static func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility:
            // Do NOT try to "live-probe" via AXUIElementCopyAttributeValue
            // on AXUIElementCreateSystemWide() - it succeeds for our
            // own focused window even when untrusted, producing false
            // positives. The result can lag for the lifetime of the
            // process when the user toggles the System Settings switch
            // on a running app; the relaunch button is the documented
            // workaround.
            return AXIsProcessTrusted()
        case .inputMonitoring:
            // IOHIDCheckAccess is the canonical way to read this without
            // triggering a prompt. The constant value is 1 (kIOHIDRequestTypeListenEvent)
            // and we use the C symbol directly rather than importing the
            // private header.
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        }
    }

    static func allGranted() -> Bool {
        Kind.allCases.allSatisfy(isGranted)
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // The Grant-button path for microphone. requestAccess only shows the
    // system prompt while the status is .notDetermined; once the user has
    // denied, it returns false with no UI at all (macOS never re-prompts a
    // denied app, not even after relaunch). So in the denied case we
    // deep-link to System Settings instead - the only way back. .authorized
    // never reaches here because the Grant button is hidden once granted.
    static func grantMicrophone(_ completion: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            requestMicrophone { _ in completion() }
        default:
            openSettings(for: .microphone)
            completion()
        }
    }

    // Triggers the macOS prompt and adds Purr to the Accessibility
    // list in System Settings. Only prompts on the very first call - after
    // the user dismisses or denies, the user must toggle manually in
    // System Settings (which `openSettings(for:)` deeplinks them to).
    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // Same idea for Input Monitoring (macOS 10.15+): first call shows the
    // prompt, subsequent calls just check.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openSettings(for kind: Kind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }

    // System Audio Recording (kTCCServiceAudioCapture) is not one of the three
    // Kinds: it has no public authorization-status API and no programmatic
    // request - the only prompt fires automatically the first time a Core Audio
    // process tap starts, and never again once answered. So we can't show a live
    // status or a "Grant" that prompts; we can only deep-link to the pane where
    // the user toggles it. macOS groups it under "Screen & System Audio
    // Recording" (the ScreenCapture pane).
    static let systemAudioSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    static func openSystemAudioSettings() {
        NSWorkspace.shared.open(systemAudioSettingsURL)
    }
}
