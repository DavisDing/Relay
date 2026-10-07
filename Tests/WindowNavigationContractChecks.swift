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

    @MainActor static func accessibleText(in node: Any, depth: Int = 0) -> [String] {
        guard depth < 30, let element = node as? NSAccessibilityProtocol else { return [] }
        let own = [element.accessibilityLabel(), element.accessibilityValue() as? String].compactMap { $0 }
        return own + (element.accessibilityChildren() ?? []).flatMap { accessibleText(in: $0, depth: depth + 1) }
    }

    @MainActor static func run() async throws {
        let repository = DetailFailureRepository()
        let configuration = AccountConfiguration(displayName: "Navigation fixture (offline)", providerKind: .pipio,
                                                 siteOrigin: URL(string: "https://example.invalid")!)
        try repository.upsertAccount(configuration)
        let store = RelayStore(repository: repository, credentialStore: InMemoryCredentialStore(),
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
        let detail: (AccountModel) -> Void = try field("onPresentDetail", in: host.rootView)
        let account = store.accounts[0]
        func currentWindow() throws -> NSWindow? {
            let windowController: NSWindowController? = try field("auxiliaryWindowController", in: controller)
            return windowController?.window
        }
        let routes: [(String, () -> Void)] = [
            ("settings", settings), ("add", add), ("edit", { edit(account) }),
            ("detail", { detail(account) })
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
        // Verify SwiftUI observes changes while the real detail window stays open.
        // This exercises the hosted container, not only the store projection.
        detail(account)
        try await settle()
        guard let detailWindow = try currentWindow(), let detailView = detailWindow.contentView else {
            throw NavigationCheckFailure(message: "Missing live detail window")
        }
        let initialText = accessibleText(in: detailView)
        try check(initialText.contains(where: { $0.contains(configuration.displayName) }), "Initial detail is rendered")
        var updatedConfiguration = configuration
        updatedConfiguration.displayName = "Updated detail fixture"
        try repository.upsertAccount(updatedConfiguration)
        let updatedSnapshot = ProviderSnapshot(
            accountID: configuration.id, balance: MoneyValue(amount: 321, currency: .cny),
            todaySpend: MoneyValue(amount: 7, currency: .cny), monthSpend: MoneyValue(amount: 21, currency: .cny),
            requestCount: nil, capabilities: [.balance], freshness: .fresh,
            rate: AccountRate(accountID: configuration.id, source: .providerNativeCurrency, nativeCurrency: .cny)
        )
        try repository.upsertSnapshot(updatedSnapshot)
        store.updateTemporalPresentation(at: updatedSnapshot.fetchedAt)
        try await settle()
        let updatedText = accessibleText(in: detailView)
        try check(updatedText.contains(where: { $0.contains(updatedConfiguration.displayName) }), "Open detail observes the latest account")
        try check(updatedText.contains(where: { $0.contains(RelayNumberFormatter.money(321, currency: .cny)) }), "Open detail renders the latest balance")
        try check(try currentWindow() === detailWindow, "Data updates retain the same detail window")
        // Hidden details retain observation and receive changes before reopening.
        controller.close()
        updatedConfiguration.displayName = "Updated while hidden"
        try repository.upsertAccount(updatedConfiguration)
        store.updateTemporalPresentation(at: updatedSnapshot.fetchedAt)
        controller.toggle()
        try await settle()
        try check(try currentWindow() === detailWindow, "Reopening retains the detail window")
        try check(accessibleText(in: detailView).contains(where: { $0.contains(updatedConfiguration.displayName) }), "Reopened detail displays latest data")
        repository.failAccountReads = true
        store.updateTemporalPresentation(at: updatedSnapshot.fetchedAt)
        try await settle()
        try check(try currentWindow() === detailWindow, "Temporary read failure keeps the same detail window")
        let failedText = accessibleText(in: detailView)
        try check(failedText.contains(where: { $0.contains(updatedConfiguration.displayName) }), "Read failure retains last successful detail")
        try check(failedText.contains(where: { $0.contains("读取失败，保留上次数据") }), "Read failure is visible in existing footer")
        repository.failAccountReads = false
        store.updateTemporalPresentation(at: updatedSnapshot.fetchedAt)
        try await settle()
        try check(try currentWindow() === detailWindow, "Recovery keeps the same detail window")
        try check(!accessibleText(in: detailView).contains(where: { $0.contains("读取失败，保留上次数据") }), "Recovery clears the footer error")
        try repository.deleteAccount(id: configuration.id)
        store.updateTemporalPresentation(at: updatedSnapshot.fetchedAt)
        try await settle()
        try check(try currentWindow() == nil && popover.isShown, "Deleted detail returns home instead of showing stale data")
        print("PASSED: hosted detail updates visible/hidden data without replacing the window; removal returns home")

        let gateway = AccountConfiguration(displayName: "Gateway detail fixture", providerKind: .workbuddy2api,
                                           siteOrigin: URL(string: "https://gateway.example.invalid")!)
        let child = ProviderSubAccountSnapshot(parentAccountID: gateway.id, externalID: "uid-1", displayName: "Gateway child fixture", availablePoints: 125)
        try repository.upsertAccount(gateway)
        try repository.upsertSnapshot(ProviderSnapshot(
            accountID: gateway.id, balance: nil, todaySpend: nil, monthSpend: nil, requestCount: nil,
            capabilities: [.creditBalance], freshness: .fresh,
            rate: AccountRate(accountID: gateway.id, source: .providerNativeCurrency, nativeCurrency: .cny), subAccounts: [child]
        ))
        store.updateTemporalPresentation(at: Date())
        guard let childModel = store.dashboardAccounts.first else { throw NavigationCheckFailure(message: "Missing gateway child fixture") }
        detail(childModel)
        try await settle()
        guard let childWindow = try currentWindow(), let childView = childWindow.contentView else {
            throw NavigationCheckFailure(message: "Missing child detail window")
        }
        store.setHidden(accountID: gateway.id, hidden: true)
        try await settle()
        try check(try currentWindow() === childWindow, "Hiding gateway does not close child detail")
        store.setEnabled(accountID: gateway.id, enabled: false)
        try await settle()
        try check(try currentWindow() === childWindow, "Disabling gateway does not close child detail")
        try check(accessibleText(in: childView).contains(where: { $0.contains(child.displayName) }), "Disabled child retains displayed data")
        childWindow.close()
        try await settle()
        try check(popover.isShown, "Child detail still returns home explicitly")
        print("PASSED: detail read failure/recovery and hidden/disabled gateway retention")

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
