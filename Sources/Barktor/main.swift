import AppKit

// Manual NSApplication bootstrap instead of @main / SwiftUI App. Two reasons:
//
// 1. We want a pure menu-bar app (LSUIElement = true). SwiftUI's App
//    lifecycle insists on at least one Scene, which forces window plumbing
//    we don't need and makes MenuBarExtra-vs-NSStatusItem decisions awkward
//    on macOS 13.
//
// 2. The hotkey + audio + transcription pipeline is fundamentally an
//    AppKit/Combine system. Driving it from a SwiftUI scene root would mean
//    weaving lifecycle hooks through the View tree. AppDelegate is the
//    right home.

// Before anything can read UserDefaults or touch Application Support:
// upgrades from the pre-rename identity (Purr) move their data across here.
LegacyMigration.run()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
