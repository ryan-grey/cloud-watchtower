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

    /// Directories whose contents do not survive. A login item is a path plus a promise to
    /// launch it every morning, so registering a bundle sitting in one of these produces a
    /// login item that works until the directory is swept and then fails silently forever.
    ///
    /// This is not hypothetical. On 2026-08-31 the login item pointed at
    /// `/private/tmp/…/scratchpad/Watchtower.app` — a build that had been run once out of a
    /// scratch directory and had registered itself on the way past. The directory was later
    /// swept into `/private/var/dirs_cleaner/`, and from then on every login tried to launch
    /// a bundle that was not there. Nothing reported it: the login item was still listed and
    /// still enabled, and the app was simply never running.
    private static let volatilePrefixes = [
        "/private/tmp/", "/tmp/",
        "/private/var/folders/", "/var/folders/",
        "/private/var/dirs_cleaner/", "/var/dirs_cleaner/",
        "/private/var/tmp/", "/var/tmp/",
    ]

    /// Where this bundle actually is, symlinks resolved — `/tmp` is a symlink to
    /// `/private/tmp`, so comparing the unresolved path would miss half the cases.
    private static var bundlePath: String {
        Bundle.main.bundleURL.resolvingSymlinksInPath().path
    }

    /// Nil when this bundle is somewhere a login item can point at, otherwise why not.
    static var unstableLocation: String? {
        let path = bundlePath
        guard volatilePrefixes.contains(where: { path.hasPrefix($0) })
            || path.contains("/DerivedData/") else { return nil }
        return path
    }

    /// Returns nil on success, or a message to show in the panel on failure.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        guard isAvailable else { return "Not running from an app bundle" }
        // Only guards registration. Unregistering from a temporary copy must stay possible —
        // that is exactly how you clean up after one has captured the login item.
        if enabled, let path = unstableLocation {
            return "Not registering: this copy is in a temporary directory that will be "
                 + "deleted (\(path)). Move the app somewhere permanent — /Applications or "
                 + "~/Applications — and turn this on from there."
        }
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
