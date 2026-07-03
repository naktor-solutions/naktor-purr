import Foundation
import os

// One-time, best-effort migration from the app's pre-rename identity
// (Purr, com.naktor.purr) so a 0.2.x install upgrades in place with its
// settings, dictation history, downloaded models, and meeting transcripts
// intact.
//
// Must run before anything reads UserDefaults.standard or touches
// Application Support: SettingsStore captures defaults values in its init,
// and HistoryStore/ModelManager create their directories on first use.
// main.swift calls `run()` before constructing the AppDelegate.
enum LegacyMigration {
    static let legacyBundleID = "com.naktor.purr"
    // Deliberately outside SettingsStore.Keys: "Reset all settings" clears
    // those, and a cleared marker would silently re-import the old values.
    private static let markerKey = "migration.legacyPurrImported"
    private static let log = Logger(subsystem: "com.naktor.barktor", category: "migration")

    static func run() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        migrateSupportDirectory(at: support, fm: fm)
        migrateDefaults(supportPath: support.path)
    }

    // MARK: - Application Support

    // Moves ~/Library/Application Support/Purr -> Barktor wholesale. Same
    // volume, so it's a rename - models measured in GB are never copied -
    // then folds the legacy "Purr Meetings" folder name into "Meetings".
    // A pre-existing Barktor folder means migration (or a fresh install)
    // already happened, so the legacy folder is left untouched.
    static func migrateSupportDirectory(at support: URL, fm: FileManager) {
        let old = support.appendingPathComponent("Purr", isDirectory: true)
        let new = support.appendingPathComponent("Barktor", isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do {
            try fm.moveItem(at: old, to: new)
            let oldMeetings = new.appendingPathComponent("Purr Meetings", isDirectory: true)
            let newMeetings = new.appendingPathComponent("Meetings", isDirectory: true)
            if fm.fileExists(atPath: oldMeetings.path), !fm.fileExists(atPath: newMeetings.path) {
                try fm.moveItem(at: oldMeetings, to: newMeetings)
            }
            log.info("migrated legacy Application Support/Purr")
        } catch {
            // Leave whatever moved in place; every store falls back to
            // creating fresh directories, so the app still launches.
            log.error("support-dir migration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - UserDefaults

    // Imports every value from the old defaults domain that the new domain
    // doesn't already have, then rewrites the stored meetings path if it
    // pointed inside the folder migrateSupportDirectory just moved.
    static func migrateDefaults(supportPath: String, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: markerKey) else { return }
        defaults.set(true, forKey: markerKey)
        guard
            let keys = CFPreferencesCopyKeyList(
                legacyBundleID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                as? [String],
            !keys.isEmpty
        else { return }
        let values =
            CFPreferencesCopyMultiple(
                keys as CFArray, legacyBundleID as CFString,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
        for (key, value) in values where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        let pathKey = SettingsStore.Keys.meetingsFolderPath
        if let path = defaults.string(forKey: pathKey), !path.isEmpty {
            let rewritten = rewriteLegacyPath(path, supportPath: supportPath)
            if rewritten != path { defaults.set(rewritten, forKey: pathKey) }
        }
        log.info("imported \(values.count) legacy defaults from \(legacyBundleID)")
    }

    // MARK: - Path rewriting

    // "<support>/Purr/..." -> "<support>/Barktor/...", then the old default
    // meetings folder "<support>/Barktor/Purr Meetings" -> ".../Meetings",
    // mirroring what migrateSupportDirectory did on disk. Any path outside
    // the migrated tree comes back unchanged.
    static func rewriteLegacyPath(_ path: String, supportPath: String) -> String {
        let oldRoot = supportPath + "/Purr"
        let newRoot = supportPath + "/Barktor"
        var out = path
        if out == oldRoot || out.hasPrefix(oldRoot + "/") {
            out = newRoot + out.dropFirst(oldRoot.count)
        }
        let oldMeetings = newRoot + "/Purr Meetings"
        if out == oldMeetings || out.hasPrefix(oldMeetings + "/") {
            out = newRoot + "/Meetings" + out.dropFirst(oldMeetings.count)
        }
        return out
    }
}
