import Foundation
import ServiceManagement

/// Login-item registration. SMAppService needs a real bundle with a bundle identifier, which
/// is why `scripts/make-app.sh` assembles one rather than shipping a bare executable.
enum LaunchAtLogin {

    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, or a message to show in the panel on failure.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        guard isAvailable else { return "Not running from an app bundle" }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
