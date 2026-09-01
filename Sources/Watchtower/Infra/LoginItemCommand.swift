import Foundation
import ServiceManagement

/// `--login-item status|register|unregister`.
///
/// The panel has a toggle for this and that is the normal way in. This exists because the
/// one failure worth having a command for is a login item that has stopped working, and in
/// that state the app is not running, so there is no panel to click.
///
/// On 2026-08-31 the registration pointed at a build that had been run once out of a scratch
/// directory. The directory was swept; the login item stayed listed and stayed "enabled";
/// the app simply never started again. `status` is written to make that visible in one line
/// rather than requiring a trip through `sfltool dumpbtm`.
enum LoginItemCommand {

    static func runAndExit(_ verb: String) -> Never {
        switch verb {
        case "status":
            print("Login item")
            print("  bundle      \(Bundle.main.bundleURL.resolvingSymlinksInPath().path)")
            print("  identifier  \(Bundle.main.bundleIdentifier ?? "(none)")")
            print("  status      \(describe(SMAppService.mainApp.status))")
            if let path = LaunchAtLogin.unstableLocation {
                print("  location    UNSTABLE — \(path)")
                print("")
                print("  This copy is in a directory that gets deleted. Registering it would")
                print("  produce a login item that works until the sweep and then fails")
                print("  silently. Move the app to /Applications or ~/Applications first.")
            } else {
                print("  location    ok (a permanent directory)")
            }
            exit(0)

        case "register":
            if let problem = LaunchAtLogin.set(true) {
                FileHandle.standardError.write(Data((problem + "\n").utf8))
                exit(1)
            }
            print("registered: \(Bundle.main.bundleURL.resolvingSymlinksInPath().path)")
            print("status: \(describe(SMAppService.mainApp.status))")
            exit(0)

        case "unregister":
            if let problem = LaunchAtLogin.set(false) {
                FileHandle.standardError.write(Data((problem + "\n").utf8))
                exit(1)
            }
            print("unregistered")
            print("status: \(describe(SMAppService.mainApp.status))")
            exit(0)

        default:
            FileHandle.standardError.write(
                Data("usage: --login-item status|register|unregister\n".utf8))
            exit(2)
        }
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled:        return "enabled"
        case .notRegistered:  return "not registered"
        case .notFound:       return "not found"
        case .requiresApproval:
            return "requires approval (enable it in System Settings > General > Login Items)"
        @unknown default:     return "unknown (\(status.rawValue))"
        }
    }
}
