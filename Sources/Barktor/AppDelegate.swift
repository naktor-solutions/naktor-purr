import AppKit
import SwiftUI

// AppDelegate owns long-lived singletons. It does no work itself - the
// pipeline lives in AppCoordinator, the menu bar in MenuBarController, and
// settings in SettingsStore. Keeping this thin makes it easy to find where
// any given behaviour actually lives.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator!
    private var menuBar: MenuBarController!
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = AppCoordinator()
        menuBar = MenuBarController(
            coordinator: coordinator,
            onShowAbout: { [weak self] in self?.showAbout() },
            onShowSettings: { [weak self] in self?.showSettings() },
            onShowHistory: { [weak self] in self?.showHistory() },
            onShowOnboarding: { [weak self] in self?.showOnboarding() },
            onQuit: { NSApp.terminate(nil) }
        )

        // Wire the global Quit hotkey (⌃⌥Q) through the same closure the
        // status-bar Quit item uses, so a hotkey press and a menu click are
        // indistinguishable downstream.
        coordinator.setMenuActions(
            quit: { NSApp.terminate(nil) }
        )

        coordinator.start()

        if !SettingsStore.shared.onboardingDone || !Permissions.allGranted() {
            // First launch, or a regression from a permission being revoked
            // (System Settings can flip these any time): walk the user
            // through the three TCC prompts before they try to use a hotkey
            // that won't fire.
            showOnboarding()
        }
    }

    // Barktor has no Dock icon, and a crowded menu bar (or the notch) can push
    // its status item out of sight - leaving no visible way into the app.
    // Opening Barktor again from Finder/Launchpad/Spotlight lands here: surface
    // the right window instead of doing nothing. Onboarding while setup is
    // incomplete, Settings otherwise.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            if !SettingsStore.shared.onboardingDone || !Permissions.allGranted() {
                showOnboarding()
            } else {
                showSettings()
            }
        }
        // With windows already visible, returning true lets AppKit bring
        // them to the front.
        return true
    }

    private func showOnboarding() {
        if let win = onboardingWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // textSelection lets the user drag-select and copy any text in the
        // window (permission descriptions, shortcuts) out to other apps.
        // "Start Using Barktor" closes this window; the app stays alive in the
        // menu bar (isReleasedWhenClosed is false, so it can be reopened from
        // the menu). The window isn't assigned to onboardingWindow until below,
        // so capture self and read it lazily when the button fires.
        let view = OnboardingView(onFinish: { [weak self] in self?.onboardingWindow?.close() })
            .textSelection(.enabled)
        let host = NSHostingController(rootView: view)
        // Size the window to the SwiftUI content's ideal size. OnboardingView
        // pins its own width, so this yields a window sized exactly to the
        // content - no clipping, no empty padding.
        host.sizingOptions = .preferredContentSize
        let win = NSWindow(contentViewController: host)
        win.title = "Welcome to Barktor"
        win.styleMask = [.titled, .closable]
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = win
    }

    private func showAbout() {
        if let win = aboutWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = AboutView(updater: updater, coordinator: coordinator).textSelection(.enabled)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "About Barktor"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 380, height: 332))
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow = win
    }

    private func showSettings() {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(
            coordinator: coordinator,
            onShowAbout: { [weak self] in self?.showAbout() }
        ).textSelection(.enabled)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Barktor - Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 560, height: 600))
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = win
    }

    private func showHistory() {
        if let win = historyWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = HistoryView(coordinator: coordinator).textSelection(.enabled)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Barktor - History"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 560, height: 520))
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        historyWindow = win
    }
}
