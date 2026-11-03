import AppKit

@MainActor
final class RelayApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var menuBarController: RelayMenuBarController?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        menuBarController?.prepareForTermination() == false ? .terminateCancel : .terminateNow
    }
}
