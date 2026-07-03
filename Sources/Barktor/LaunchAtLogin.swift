import ServiceManagement

// Wraps SMAppService.mainApp so the Settings toggle reflects reality even
// when the login item is flipped in System Settings instead of here. Status
// is re-read after every mutation and on view appearance - SMAppService has
// no change notifications.
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var isEnabled: Bool

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // The OS may defer or refuse (e.g. user must approve in System
            // Settings). Truth over intent: re-read status either way.
        }
        refresh()
    }
}
