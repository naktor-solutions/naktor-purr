import AppKit
import SwiftUI

// First-run setup: a three-step permissions walkthrough plus a picker for
// where meetings are saved. macOS doesn't let us mass-prompt or auto-grant
// permissions; the best we can do is explain what each toggle is for and
// deeplink to the right pane in System Settings. The view polls every
// second for the live state of each permission.
//
// Microphone updates live - its green check appears as soon as it's
// granted. Accessibility and Input Monitoring do NOT: macOS only exposes
// those grants to a freshly launched process (AXIsProcessTrusted and
// IOHIDCheckAccess keep returning the stale pre-grant value for the life
// of the process - a known, unfixed macOS behaviour). So once the user has
// been sent to System Settings for those two, the row swaps its "Grant"
// button for "Restart": relaunching is the only way to pick the grant up.
struct OnboardingView: View {
    // Dismisses the onboarding window; the app keeps running in the menu bar
    // afterward (it's an .accessory/LSUIElement app). Wired by AppDelegate to
    // close the hosting window.
    let onFinish: () -> Void

    @State private var status: [Permissions.Kind: Bool] = [:]
    @State private var pollTimer: Timer?
    @State private var observers: [NSObjectProtocol] = []
    // Permissions the user has been sent to System Settings to grant, whose
    // result this process can't observe until it relaunches.
    @State private var awaitingRestart: Set<Permissions.Kind> = []
    @ObservedObject private var settings = SettingsStore.shared

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                Text("Welcome to Barktor")
                    .font(.title2.weight(.semibold))
            }

            VStack(spacing: 10) {
                ForEach(Permissions.Kind.allCases) { kind in
                    permissionRow(kind: kind)
                }
            }

            meetingsFolderRow

            systemAudioNote

            HStack {
                // The default (accented, right-hand) button is whichever step
                // actually moves the user forward. When a permission was just
                // toggled in System Settings, this process can't see the grant
                // until it relaunches - so Restart is the real "finish setup"
                // action and leads. Otherwise nothing is left but to start
                // using the app, so that leads and Restart drops back to a
                // quiet fixer for a grant that stubbornly reads grey.
                if restartPending {
                    Button("Start Using Barktor") { finish() }
                    Spacer()
                    Button("Restart Barktor") { quitAndRelaunch() }
                        .keyboardShortcut(.defaultAction)
                        .help(restartHelp)
                } else {
                    Button("Restart Barktor") { quitAndRelaunch() }
                        .help(restartHelp)
                    Spacer()
                    Button("Start Using Barktor") { finish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        // Pin the width so the view has one definite ideal size. Without
        // this, NSHostingController can't derive a stable window size from
        // the content (text views have no intrinsic width) and the window
        // opens oversized and empty. Height stays content-driven.
        .frame(width: 520)
        .onAppear {
            // Re-register the current binary's cdhash with TCC. After every
            // ad-hoc rebuild the cdhash changes; without this call the new
            // binary either isn't listed in System Settings at all, or the
            // existing "Barktor" row points at a stale signature and the
            // app appears denied even when the toggle is on. These calls
            // prompt only the first time TCC sees a given (bundleID, cdhash)
            // pair, so re-running onboarding later is silent.
            _ = Permissions.requestAccessibility()
            _ = Permissions.requestInputMonitoring()

            refresh()

            // Polling is the safety net for "user toggled the switch in
            // System Settings while onboarding was open." 1s is plenty.
            // .common runloop mode keeps it alive during window dragging
            // and modal sheets.
            let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in self.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer

            // Eager refresh when the user comes back from System Settings.
            // The onboarding window regains key status (or the app regains
            // active status) the moment they switch back. These notifications
            // let us update green checks instantly instead of waiting up to
            // a full polling cycle.
            let center = NotificationCenter.default
            let onKey = center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in self.refresh() }
            }
            let onActive = center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in self.refresh() }
            }
            observers = [onKey, onActive]
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
            for token in observers {
                NotificationCenter.default.removeObserver(token)
            }
            observers.removeAll()
        }
    }

    private func refresh() {
        for kind in Permissions.Kind.allCases {
            status[kind] = Permissions.isGranted(kind)
        }
    }

    // True when the user was sent to System Settings to grant Accessibility or
    // Input Monitoring but this process still can't see the grant. macOS only
    // exposes those to a freshly launched process, so a relaunch is the only
    // thing that finishes setup - the bottom bar leads with Restart while true.
    private var restartPending: Bool {
        awaitingRestart.contains { !(status[$0] ?? false) }
    }

    private var restartHelp: String {
        "If a permission stays grey after you toggled it on in System Settings, restart Barktor so macOS re-reads the trust state for this process."
    }

    // Marks onboarding complete and closes the window. The app keeps running in
    // the menu bar - the friendly counterpart to the old "Quit Barktor" ending.
    private func finish() {
        SettingsStore.shared.onboardingDone = true
        onFinish()
    }

    // Detached shell helper waits for the current PID to exit, then
    // re-opens the bundle. Surviving NSApp.terminate requires the
    // helper to be reparented away from us, which `Process` + a /tmp
    // script achieves.
    private func quitAndRelaunch() {
        let appPath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("barktor-relaunch-\(UUID().uuidString).sh")
        // `open -n` forces a new instance. Without it LaunchServices
        // can briefly route back to the just-quit process's cached
        // state, defeating the relaunch.
        let script = """
            #!/bin/sh
            set -u
            i=0
            while kill -0 \(pid) 2>/dev/null; do
                i=$((i+1))
                if [ "$i" -gt 150 ]; then break; fi
                sleep 0.2
            done
            open -n "\(appPath)"
            """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = [scriptURL.path]
            try task.run()
        } catch {
            // Helper spawn failed; we still quit and let the user re-open
            // manually rather than appearing stuck.
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.terminate(nil)
        }
    }

    // System Audio Recording is not a fourth row: it's only used by meeting
    // recording, and macOS exposes no API to request or track it ahead of
    // time. So onboarding explains it and offers a deep-link to the pane; the
    // actual prompt fires in context the first time the user records a meeting.
    private var systemAudioNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding(.top, 1)
            Text("Provide system audio recording access for Meeting Mode")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Open Settings") {
                Permissions.openSystemAudioSettings()
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    // Lets the user pick where meeting transcripts are saved. Optional: when
    // left unset, meetings save to the default Application Support folder,
    // which needs no file-access consent. A custom folder is stored as a plain
    // path - the app isn't sandboxed, so no security-scoped bookmark is needed.
    private var meetingsFolderRow: some View {
        let isDefault = settings.meetingsFolderPath.isEmpty
        // Show the full location for both states (default and chosen), e.g.
        // ~/Library/Application Support/Barktor/Meetings, rather than a generic
        // "Default" label.
        let folderPath =
            isDefault
            ? SettingsStore.defaultMeetingsDirectory.path
            : settings.meetingsFolderPath
        let displayPath = (folderPath as NSString).abbreviatingWithTildeInPath
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .font(.title3)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Meetings folder").font(.body.weight(.medium))
                Text(displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button("Choose…") { chooseMeetingsFolder() }
                    .controlSize(.small)
                if !isDefault {
                    Button("Use Default") { settings.meetingsFolderPath = "" }
                        .controlSize(.small)
                        .buttonStyle(.link)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func chooseMeetingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder to save meeting transcripts"
        if !settings.meetingsFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: settings.meetingsFolderPath, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            // Probe-write now to force any macOS file-access prompt in context,
            // instead of silently at the first meeting-stop. If the folder is in
            // a TCC-protected location (Desktop/Documents/Downloads, a cloud or
            // removable volume) and the user denies, we keep the previous setting
            // rather than store an unwritable path that would later trigger the
            // silent fallback to the default folder.
            if canWriteMeetings(to: url) {
                settings.meetingsFolderPath = url.path
            } else {
                warnFolderNotWritable(url)
            }
        }
    }

    // Writes and deletes a zero-byte probe file. The write is what triggers
    // the macOS prompt for protected folders, so consent (or denial) is
    // resolved here at selection time. Returns false if the folder isn't
    // writable.
    private func canWriteMeetings(to dir: URL) -> Bool {
        let probe = dir.appendingPathComponent(".barktor-write-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    private func warnFolderNotWritable(_ url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Can't save meetings to that folder"
        alert.informativeText = """
            Barktor couldn't write to "\(url.lastPathComponent)". If it's in your \
            Desktop, Documents, Downloads, or a cloud/removable drive, allow access \
            in System Settings › Privacy & Security › Files and Folders, then choose \
            it again. Until then, meetings keep saving to the default folder.
            """
        alert.runModal()
    }

    @ViewBuilder
    private func permissionRow(kind: Permissions.Kind) -> some View {
        let granted = status[kind] ?? false
        // macOS hides Accessibility / Input Monitoring grants from the
        // running process, so after the user visits System Settings the row
        // asks for a relaunch instead of pretending the grant will appear.
        let needsRestart = !granted && awaitingRestart.contains(kind)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title3)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.body.weight(.medium))
                Text(kind.why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if needsRestart {
                Button("Restart") { quitAndRelaunch() }
                    .controlSize(.small)
            } else if !granted {
                Button("Grant") {
                    switch kind {
                    case .microphone:
                        // Prompt only while undecided; if the user already
                        // denied, the prompt never returns, so this deep-links
                        // to System Settings instead. Status updates live, so
                        // no restart needed.
                        Permissions.grantMicrophone { refresh() }
                    case .accessibility:
                        // Request first - this registers the app in the
                        // Accessibility list and shows the system prompt
                        // on the very first call. Then open Settings so
                        // the user can flip the toggle.
                        Permissions.requestAccessibility()
                        Permissions.openSettings(for: kind)
                        awaitingRestart.insert(kind)
                    case .inputMonitoring:
                        Permissions.requestInputMonitoring()
                        Permissions.openSettings(for: kind)
                        awaitingRestart.insert(kind)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}
