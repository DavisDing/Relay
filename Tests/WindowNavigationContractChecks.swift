import AppKit
import SwiftUI

private struct NavigationCheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

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

    /// Poll the observable result, rather than relying on one fixed rendering delay.
    @MainActor static func eventually(_ message: String, _ condition: () throws -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while try !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw NavigationCheckFailure(message: "Timed out: \(message)")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor static func accessibleText(in node: Any, depth: Int = 0) -> [String] {
        guard depth < 30, let element = node as? NSAccessibilityProtocol else { return [] }
        let own = [element.accessibilityLabel(), element.accessibilityValue() as? String].compactMap { $0 }
        return own + (element.accessibilityChildren() ?? []).flatMap { accessibleText(in: $0, depth: depth + 1) }
    }

    @MainActor static func textFields(in view: NSView) -> [NSTextField] {
        ([view as? NSTextField].compactMap { $0 }) + view.subviews.flatMap { textFields(in: $0) }
    }

    @MainActor static func editText(_ value: String, in field: NSTextField, window: NSWindow) throws {
        try check(window.makeFirstResponder(field), "Fixture input accepts focus")
        guard let editor = field.currentEditor() as? NSTextView else {
            throw NavigationCheckFailure(message: "Missing field editor")
        }
        editor.selectAll(nil)
        editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        window.makeFirstResponder(window.initialFirstResponder)
    }

    @MainActor static func press(_ label: String, in node: Any, depth: Int = 0) -> Bool {
        guard depth < 30, let element = node as? NSAccessibilityProtocol else { return false }
        if element.accessibilityRole() == .button, element.accessibilityLabel() == label {
            return element.accessibilityPerformPress()
        }
        return (element.accessibilityChildren() ?? []).contains { press(label, in: $0, depth: depth + 1) }
    }

    @MainActor static func run() async throws {
        let repository = DetailFailureRepository()
        let configuration = AccountConfiguration(displayName: "Navigation fixture (offline)", providerKind: .pipio,
                                                 siteOrigin: URL(string: "https://example.invalid")!)
        try repository.upsertAccount(configuration)
        let store = RelayStore(repository: repository, credentialStore: InMemoryCredentialStore(),
                               adapters: ProviderAdapterRegistry(adapters: []), automaticallyRefresh: false)
        let controller = RelayMenuBarController(store: store)
        defer {
            // Cleanup must not enqueue another home presentation, even on failure.
            let owner: NSWindowController? = try? field("auxiliaryWindowController", in: controller)
            owner?.window?.delegate = nil
            owner?.close()
            controller.close()
        }
        let popover: NSPopover = try field("popover", in: controller)
        let statusItem: NSStatusItem = try field("statusItem", in: controller)
        guard let button = statusItem.button else {
            throw NavigationCheckFailure(message: "Missing status button")
        }
        func latchStatusButton() {
            button.state = .on
            button.highlight(true)
        }
        func statusButtonIsReleased() -> Bool {
            button.state == .off && !button.isHighlighted
        }
        // Inject a retained press into the actual AppKit button. Dispatch its
        // action rather than calling toggle(), so the mouse-action path is covered.
        // This does not replace manual mouse tracking / visual verification.
        latchStatusButton()
        try check(!statusButtonIsReleased(), "Retained-press fixture is active")
        try check(button.sendAction(button.action, to: button.target), "Status button has a working action")
        try check(!popover.isShown, "Status action waits for native button tracking to finish")
        try await eventually("status action opens home and releases its press") {
            popover.isShown && statusButtonIsReleased()
        }
        latchStatusButton()
        try check(button.sendAction(button.action, to: button.target), "Status button can toggle home closed")
        try await eventually("second status action closes home and releases its press") {
            !popover.isShown && statusButtonIsReleased()
        }
        controller.toggle()
        try await eventually("home is ready for native close") { popover.isShown }
        latchStatusButton()
        popover.close()
        try await eventually("native popover close releases the status button") {
            !popover.isShown && statusButtonIsReleased()
        }
        latchStatusButton()
        controller.close()
        try check(statusButtonIsReleased(), "Closing an already hidden panel releases its press")
        controller.toggle()
        try await eventually("home is ready for focus loss") { popover.isShown }
        latchStatusButton()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        try await eventually("focus loss hides home and releases the status button") {
            !popover.isShown && statusButtonIsReleased()
        }
        print("PASSED: injected status-button press releases after action dispatch, native close and focus loss")
        guard let host = popover.contentViewController as? NSHostingController<MainPopoverView> else {
            throw NavigationCheckFailure(message: "Missing dashboard host")
        }
        let settings: () -> Void = try field("onPresentSettings", in: host.rootView)
        let manage: (() -> Void)? = try field("onPresentAccountManagement", in: host.rootView)
        let add: () -> Void = try field("onPresentAddAccount", in: host.rootView)
        let edit: (AccountModel) -> Void = try field("onPresentEdit", in: host.rootView)
        let detail: (AccountModel) -> Void = try field("onPresentDetail", in: host.rootView)
        let consumption: (() -> Void)? = try field("onPresentConsumptionOverview", in: host.rootView)
        let account = store.accounts[0]
        func currentWindow() throws -> NSWindow? {
            let windowController: NSWindowController? = try field("auxiliaryWindowController", in: controller)
            return windowController?.window
        }
        let routes: [(String, () -> Void)] = [
            ("settings", settings), ("add", add), ("edit", { edit(account) }),
            ("detail", { detail(account) }), ("consumption", { consumption?() })
        ]
        controller.toggle()
        try await eventually("menu-bar anchor can show home") { popover.isShown }
        for (name, open) in routes {
            latchStatusButton()
            open()
            try await eventually("opening \(name) displays its window") { try currentWindow()?.isVisible == true }
            try check(statusButtonIsReleased(), "Opening \(name) releases the status button")
            guard let window = try currentWindow() else { throw NavigationCheckFailure(message: "No \(name) window") }
            try check(window.styleMask.contains(.borderless), "\(name) uses the shared borderless panel shell")
            try check(!window.styleMask.contains(.titled), "\(name) does not show a native title bar")
            try check(window.isOpaque == false, "\(name) keeps the panel surface transparent outside its rounded content")
            try check(!popover.isShown, "Opening \(name) hides home")
            try check(window.canBecomeKey && window.canBecomeMain, "\(name) accepts keyboard focus")
            try await eventually("\(name) initially focuses a neutral responder") {
                window.firstResponder is RelayInitialFocusView
            }
            try check(window.isReleasedWhenClosed == false && window.isRestorable == false,
                      "\(name) keeps the existing transient panel lifecycle")

            // Hiding is not closing: preserve each route's exact window and content.
            let contentView = window.contentView
            latchStatusButton()
            controller.close()
            try await settle()
            try check(statusButtonIsReleased(), "Hiding \(name) releases the status button")
            try check(!window.isVisible && !popover.isShown, "Hiding \(name) does not return home")
            try check(try currentWindow() === window, "Hiding \(name) retains the page")
            latchStatusButton()
            controller.toggle()
            try await eventually("reopening \(name) restores its window") { window.isVisible }
            try check(statusButtonIsReleased(), "Restoring \(name) releases the status button")
            try check(try currentWindow() === window && window.contentView === contentView && !popover.isShown,
                      "Reopening \(name) preserves the window and hosted content")

            latchStatusButton()
            window.performClose(nil)
            try await eventually("native close of \(name) returns home") { try currentWindow() == nil && popover.isShown }
            try check(statusButtonIsReleased(), "Returning home from \(name) releases the status button")
            try check(!window.isVisible, "Closed \(name) does not remain visible")

            // SwiftUI close/cancel/done callbacks use NSWindowController.close().
            // Exercise that path separately from performClose without button automation.
            open()
            try await eventually("reopening \(name) creates a new page") { try currentWindow()?.isVisible == true }
            let reopenedOwner: NSWindowController? = try field("auxiliaryWindowController", in: controller)
            try check(reopenedOwner?.window !== window, "Closed \(name) is not accidentally reused")
            reopenedOwner?.close()
            try await eventually("controller close of \(name) returns home") { try currentWindow() == nil && popover.isShown }
        }
        // Exercise the actual hosted fields and native/controller/replacement
        // close paths. Synthetic decisions avoid blocking unattended checks.
        for (name, open) in [("add", add), ("edit", { edit(account) })] {
            open()
            try await eventually("\(name) dirty fixture is visible") { try currentWindow()?.isVisible == true }
            guard let window = try currentWindow(), let view = window.contentView,
                  let input = textFields(in: view).first(where: { $0.isEditable && !($0 is NSSecureTextField) }) else {
                throw NavigationCheckFailure(message: "Missing editable \(name) field")
            }
            let gate: RelayPageCloseHandler? = try field("auxiliaryCloseHandler", in: controller)
            var allowDiscard = false, prompts = 0
            gate?.confirmDiscard = { _ in prompts += 1; return allowDiscard }
            try editText("Unsaved audit fixture", in: input, window: window)
            try await settle()
            window.performClose(nil)
            try check(prompts == 1 && (try currentWindow()) === window, "Dirty \(name) rejects native close without discard")
            let owner: NSWindowController? = try field("auxiliaryWindowController", in: controller)
            owner?.close()
            try check(prompts == 2 && (try currentWindow()) === window, "Dirty \(name) rejects controller close")
            settings()
            try check(prompts == 3 && (try currentWindow()) === window, "Dirty \(name) rejects page replacement")
            let delegate = RelayApplicationDelegate()
            delegate.menuBarController = controller
            try check(delegate.applicationShouldTerminate(NSApp) == .terminateCancel && prompts == 4,
                      "Application quit protects the hosted \(name) draft")
            controller.close()
            try check(delegate.applicationShouldTerminate(NSApp) == .terminateCancel && prompts == 5,
                      "Hidden \(name) drafts remain protected on quit")
            controller.toggle()
            allowDiscard = true
            window.performClose(nil)
            try await eventually("discard closes dirty \(name)") { try currentWindow() == nil && popover.isShown }
        }
        manage?()
        try await eventually("account management route opens") { try currentWindow()?.isVisible == true }
        try check(accessibleText(in: (try currentWindow())!.contentView!).contains(where: { $0.contains(configuration.displayName) }),
                  "Account management route starts on the accounts tab")
        (try currentWindow())?.close()
        try await settle()
        // All close paths must allow the settings page to retain its draft on
        // a storage failure, including AppKit controller close and replacement.
        settings()
        try await settle()
        guard let failedSettingsWindow = try currentWindow() else {
            throw NavigationCheckFailure(message: "Missing settings failure fixture")
        }
        repository.failSettingsWrites = true
        let beforeSettingsFailure = store.settings
        failedSettingsWindow.performClose(nil)
        try await settle()
        try check(try currentWindow() === failedSettingsWindow && failedSettingsWindow.isVisible,
                  "Failed settings save blocks native close")
        try check(!popover.isShown && store.settings == beforeSettingsFailure, "Settings failure retains the current page and saved values")
        try check(accessibleText(in: failedSettingsWindow.contentView!).contains(where: { $0.contains("未保存更改") }),
                  "Settings save error is visible on the page")
        try check(accessibleText(in: failedSettingsWindow.contentView!).contains("放弃更改"),
                  "Settings save failure exposes an explicit discard exit")
        let settingsGate: RelayPageCloseHandler? = try field("auxiliaryCloseHandler", in: controller)
        var allowSettingsDiscard = false
        settingsGate?.confirmDiscard = { _ in allowSettingsDiscard }
        let delegate = RelayApplicationDelegate()
        delegate.menuBarController = controller
        try check(delegate.applicationShouldTerminate(NSApp) == .terminateCancel,
                  "Failed settings save can cancel application quit")
        allowSettingsDiscard = true
        try check(delegate.applicationShouldTerminate(NSApp) == .terminateNow,
                  "Explicit discard permits application quit after save failure")
        allowSettingsDiscard = false
        let failedOwner: NSWindowController? = try field("auxiliaryWindowController", in: controller)
        failedOwner?.close()
        try check(try currentWindow() === failedSettingsWindow && failedSettingsWindow.isVisible,
                  "Failed settings save blocks Done/controller close")
        edit(account)
        try check(try currentWindow() === failedSettingsWindow, "Failed settings save blocks replacing its page")
        controller.close()
        try check(try currentWindow() === failedSettingsWindow, "Hiding failed settings retains its draft")
        controller.toggle()
        try await settle()
        repository.failSettingsWrites = false
        failedSettingsWindow.close()
        try await eventually("retry saves settings and returns home") { try currentWindow() == nil && popover.isShown }
        print("PASSED: settings save failure retains its page for native/controller close and page replacement; retry recovers")
        settings()
        try await settle()
        repository.failSettingsWrites = true
        guard let discardWindow = try currentWindow() else { throw NavigationCheckFailure(message: "Missing discard fixture") }
        discardWindow.performClose(nil)
        try await settle()
        let discardGate: RelayPageCloseHandler? = try field("auxiliaryCloseHandler", in: controller)
        discardGate?.confirmDiscard = { _ in true }
        try check(press("放弃更改", in: discardWindow.contentView!), "Actual discard button has an accessibility action")
        try await eventually("discard exits settings despite persistent save failure") { try currentWindow() == nil && popover.isShown }
        try check(store.settings == beforeSettingsFailure, "Discard does not write the settings draft")
        repository.failSettingsWrites = false

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
        let unsyncedGateway = AccountConfiguration(displayName: "Unsynced audit gateway", providerKind: .workbuddy2api,
            siteOrigin: URL(string: "http://localhost:7999")!)
        try repository.upsertAccount(unsyncedGateway)
        store.updateTemporalPresentation(at: Date())
        controller.toggle()
        try await eventually("gateway notice appears in the actual home accessibility tree") {
            accessibleText(in: host.view).contains(where: { $0.contains("Unsynced audit gateway：尚未同步内部账号") })
        }
        controller.close()

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
        // Recheck before any AppKit initialization in case login changed during compilation.
        if let reason = GUIVerificationSession.currentUnavailableReason() {
            fputs("SKIPPED: GUI navigation unavailable: \(reason). No GUI tests ran.\n", stderr)
            exit(GUIVerificationSession.skippedExitCode)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await run()
                print("PASSED: GUI navigation integration checks (synthetic data; no real doubleMac verification)")
                exit(0)
            }
            catch { fputs("FAILED: GUI navigation: \(error)\n", stderr); exit(1) }
        }
        NSApplication.shared.run()
    }
}
