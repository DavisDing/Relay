import Foundation
import CoreGraphics
import Darwin

/// A read-only prerequisite check: never initializes NSApplication or opens a window.
/// A session is necessary, not proof that the menu-bar anchor or GUI tests work.
enum GUIVerificationSession {
    static let skippedExitCode: Int32 = 77

    static func unavailableReason(session: [String: Any]?, userID: uid_t) -> String? {
        guard let session else { return "no Quartz GUI session / WindowServer is unavailable" }
        guard userID != 0 else { return "run as the logged-in GUI user, not root" }
        guard (session[kCGSessionUserIDKey] as? NSNumber)?.uint32Value == userID else {
            return "the GUI session belongs to a different user"
        }
        guard session[kCGSessionLoginDoneKey] as? Bool == true else {
            return "no completed GUI login (login window or incomplete session)"
        }
        guard session[kCGSessionOnConsoleKey] as? Bool == true else {
            return "the logged-in GUI session is not on the active console"
        }
        return nil
    }

    static func currentUnavailableReason() -> String? {
        unavailableReason(session: CGSessionCopyCurrentDictionary() as? [String: Any], userID: getuid())
    }
}

#if RELAY_GUI_SESSION_PROBE
@main
private enum GUIVerificationSessionProbe {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--self-test"] {
            runFixtures()
            return
        }
        guard arguments.isEmpty else {
            fputs("Usage: gui-session-probe [--self-test]\n", stderr)
            exit(64)
        }
        if let reason = GUIVerificationSession.currentUnavailableReason() {
            fputs("SKIPPED: GUI navigation requires a logged-in macOS graphical session: \(reason). No GUI tests ran.\n", stderr)
            exit(GUIVerificationSession.skippedExitCode)
        }
        print("READY: logged-in GUI session detected; navigation has NOT been tested.")
    }

    private static func runFixtures() {
        let user: uid_t = 501
        let ready: [String: Any] = [
            kCGSessionUserIDKey: NSNumber(value: user),
            kCGSessionLoginDoneKey: true,
            kCGSessionOnConsoleKey: true
        ]
        var cases: [(String, [String: Any]?, uid_t, Bool)] = [
            ("ready", ready, user, true),
            ("no WindowServer", nil, user, false),
            ("empty session", [:], user, false),
            ("root", ready, 0, false),
            ("other user", ready, 502, false)
        ]
        for key in [kCGSessionUserIDKey, kCGSessionLoginDoneKey, kCGSessionOnConsoleKey] {
            var missing = ready
            missing.removeValue(forKey: key)
            cases.append(("missing \(key)", missing, user, false))
        }
        for key in [kCGSessionLoginDoneKey, kCGSessionOnConsoleKey] {
            var inactive = ready
            inactive[key] = false
            cases.append(("false \(key)", inactive, user, false))
            var malformed = ready
            malformed[key] = "true"
            cases.append(("malformed \(key)", malformed, user, false))
        }
        for (name, session, userID, expectedReady) in cases {
            let actualReady = GUIVerificationSession.unavailableReason(session: session, userID: userID) == nil
            guard actualReady == expectedReady else {
                fputs("FAILED: GUI-session guard fixture: \(name)\n", stderr)
                exit(1)
            }
        }
        print("PASSED: GUI-session guard (\(cases.count) headless fixtures; no live GUI probe or windows)")
    }
}
#endif
