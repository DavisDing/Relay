import Foundation
import ServiceManagement

/// Thin wrapper around the macOS Login Item API. Registration is intentionally
/// best-effort at the UI boundary because a raw SwiftPM executable has no
/// application bundle/login-item identity during command-line development.
public enum LaunchAtLoginService {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
