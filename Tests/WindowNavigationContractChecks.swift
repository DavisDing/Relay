import AppKit
import SwiftUI

private struct NavigationCheckFailure: Error { let message: String }

/// AppKit integration checks. Run separately in a logged-in graphical session.
/// Reflection reads the actual shell and home callbacks without adding production test APIs.
@main
struct WindowNavigationContractChecks {
    @MainActor static func field<T>(_ name: String, in owner: Any, as type: T.Type = T.self) throws -> T {
        guard let value = Mirror(reflecting: owner).children.first(where: { $0.label == name })?.value as? T else {
            throw NavigationCheckFailure(message: "Missing test observation: \(name)")
        }
        return value
    }

    @MainActor static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NavigationCheckFailure(message: message) }
    }

    @MainActor static func settle() async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    @MainActor static func run() async throws {
        let store = RelayStore(repository: InMemoryLocalRepository(), credentialStore: InMemoryCredentialStore(),
                               adapters: ProviderAdapterRegistry(adapters: []), automaticallyRefresh: false)
        let controller = RelayMenuBarController(store: store)
        defer { controller.close() }
        let popover: NSPopover = try field("popover", in: controller)
        guard let host = popover.contentViewController as? NSHostingController<MainPopoverView> else {
            throw NavigationCheckFailure(message: "Missing dashboard host")
        }
        let settings: () -> Void = try field("onPresentSettings", in: host.rootView)
        let add: () -> Void = try field("onPresentAddAccount", in: host.rootView)
        let edit: (AccountModel) -> Void = try field("onPresentEdit", in: host.rootView)
        let detail: (AccountModel, [DailySpendPoint], [ModelUsageItem]) -> Void = try field("onPresentDetail", in: host.rootView)
        let account = AccountModel(name: "Navigation fixture (offline)", kind: .pipio,
                                   baseURL: "https://example.invalid", balance: nil, currency: .usd)
        func currentWindow() throws -> NSWindow? {
            let windowController: NSWindowController? = try field("auxiliaryWindowController", in: controller)
            return windowController?.window
        }
        let routes: [(String, () -> Void)] = [
            ("settings", settings), ("add", add), ("edit", { edit(account) }),
            ("detail", { detail(account, [], []) })
        ]
        controller.toggle()
        try await settle()
        try check(popover.isShown, "Graphical test prerequisite: menu-bar anchor can show home")
        for (name, open) in routes {
            open()
            try await settle()
            guard let window = try currentWindow() else { throw NavigationCheckFailure(message: "No \(name) window") }
            try check(window.styleMask.contains(.borderless), "\(name) uses the shared borderless panel shell")
            try check(!window.styleMask.contains(.titled), "\(name) does not show a native title bar")
            try check(window.isOpaque == false, "\(name) keeps the panel surface transparent outside its rounded content")
            try check(!popover.isShown, "Opening \(name) hides home")
            window.performClose(nil)
            try await settle()
            try check(try currentWindow() == nil && popover.isShown, "Closing \(name) returns home")
        }
        settings()
        let retainedWindow = try currentWindow()
        controller.close()
        try await settle()
        try check(!popover.isShown && retainedWindow?.isVisible == false, "Hide must not reopen home")
        try check(try currentWindow() === retainedWindow, "Hide preserves the page")
        controller.toggle()
        try await settle()
        try check(retainedWindow?.isVisible == true && !popover.isShown, "Reopen restores the same page")

        // Replacing a live auxiliary window must not trigger its return-home callback.
        edit(account)
        try await settle()
        try check(try currentWindow() !== retainedWindow && !popover.isShown, "Page replacement does not flash home")

        // An explicit hide after close wins over its deferred dashboard return.
        try currentWindow()?.close()
        controller.close()
        try await settle()
        try check(!popover.isShown, "Hide cancels a queued return")

        settings()
        try currentWindow()?.close()
        add()
        try await settle()
        try check(try currentWindow() != nil && !popover.isShown, "A newer page cancels a queued return")
        try currentWindow()?.close()
        try await settle()
        try check(popover.isShown, "Replacement page still returns home when closed")
        print("PASSED: settings/add/edit/detail close to home; hide/restore, replacement and queued-return cancellation")
    }

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAILED: \(error)"); exit(1) }
        }
        NSApplication.shared.run()
    }
}
