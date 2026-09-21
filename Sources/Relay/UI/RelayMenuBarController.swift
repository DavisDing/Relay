import AppKit
import Combine
import SwiftUI

/// AppKit shell for the menu-bar popover and its auxiliary windows.
///
/// The dashboard stays a lightweight NSPopover, while forms and detail pages
/// are presented in ordinary key windows. SwiftUI sheets hosted directly by an
/// NSPopover are unreliable in accessory applications: the transient popover
/// can close or lose key-window status as soon as a sheet is interacted with.
@MainActor
public final class RelayMenuBarController: NSObject, NSWindowDelegate {
    private let store: RelayStore
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var storeObservation: AnyCancellable?
    private var globalMouseMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var auxiliaryWindowController: NSWindowController?
    private let onApplyGlobalShortcut: ((GlobalShortcutConfiguration) -> GlobalShortcutRegistrationOutcome)?

    private let statusItemAutosaveName = NSStatusItem.AutosaveName("cloud.dinghao.relay.status-item")
    private let fixedStatusItemLength: CGFloat = 140

    public init(
        store: RelayStore,
        initialGlobalShortcutConfiguration: GlobalShortcutConfiguration = GlobalShortcutConfigurationStore.load(),
        onApplyGlobalShortcut: ((GlobalShortcutConfiguration) -> GlobalShortcutRegistrationOutcome)? = nil
    ) {
        self.store = store
        self.onApplyGlobalShortcut = onApplyGlobalShortcut
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        // Keep a stable public identity and make the item non-removable. Hidden
        // Bar can still be configured by the user, but Relay no longer behaves
        // like a disposable status item or changes identity on each launch.
        statusItem.autosaveName = statusItemAutosaveName
        statusItem.behavior = []
        statusItem.isVisible = true

        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleStatusItemClick(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.toolTip = "Relay（左键打开，右键显示菜单）"
        statusItem.button?.cell?.lineBreakMode = .byTruncatingTail

        // Do not use .transient here. A transient popover is allowed to dismiss
        // itself when an accessory app presents or activates another window,
        // which made the settings and account forms appear unclickable.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentSize = NSSize(width: 400, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: MainPopoverView(
                store: store,
                initialGlobalShortcutConfiguration: initialGlobalShortcutConfiguration,
                onApplyGlobalShortcut: onApplyGlobalShortcut,
                onPresentAddAccount: { [weak self] in self?.showAddAccountWindow() },
                onPresentSettings: { [weak self] in self?.showSettingsWindow() },
                onPresentDetail: { [weak self] account, spendPoints, modelUsages in
                    self?.showAccountDetailWindow(
                        account: account,
                        spendPoints: spendPoints,
                        modelUsages: modelUsages
                    )
                },
                onPresentEdit: { [weak self] account in self?.showAccountEditWindow(account: account) }
            )
        )

        storeObservation = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatusItem() }
        }
        installDismissMonitors()
        updateStatusItem()
    }

    deinit {
        storeObservation?.cancel()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let resignActiveObserver { NotificationCenter.default.removeObserver(resignActiveObserver) }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    public func toggle() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            auxiliaryWindowController?.close()
            auxiliaryWindowController = nil
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    public func close() {
        if popover.isShown { popover.performClose(nil) }
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggle()
        }
    }

    private func installDismissMonitors() {
        // The popover is application-defined, so close it explicitly when a
        // click happens in another app. Local events are intentionally not
        // intercepted: controls in the popover and auxiliary windows must
        // receive their normal mouse events.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        }
    }

    private func showContextMenu() {
        close()
        let menu = NSMenu()
        menu.autoenablesItems = false

        let openItem = menu.addItem(
            withTitle: "打开 Relay",
            action: #selector(openPopoverFromMenu(_:)),
            keyEquivalent: ""
        )
        openItem.target = self
        openItem.isEnabled = true

        let refreshItem = menu.addItem(
            withTitle: "立即刷新",
            action: #selector(refreshFromMenu(_:)),
            keyEquivalent: ""
        )
        refreshItem.target = self
        refreshItem.isEnabled = true

        menu.addItem(.separator())
        let quitItem = menu.addItem(
            withTitle: "退出 Relay",
            action: #selector(quitFromMenu(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.isEnabled = true

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func openPopoverFromMenu(_ sender: Any?) {
        guard !popover.isShown else { return }
        toggle()
    }

    @objc private func refreshFromMenu(_ sender: Any?) {
        Task { await store.refreshAll(forceRateRefresh: true) }
    }

    @objc private func quitFromMenu(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }

    private func presentAuxiliaryWindow<Content: View>(
        title: String,
        size: NSSize,
        content: Content
    ) {
        close()
        auxiliaryWindowController?.close()

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = NSHostingController(rootView: AnyView(content))
        window.delegate = self

        let controller = NSWindowController(window: window)
        auxiliaryWindowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func closeAuxiliaryWindow() {
        auxiliaryWindowController?.close()
        auxiliaryWindowController = nil
    }

    private func showAddAccountWindow() {
        presentAuxiliaryWindow(title: "添加服务商账号", size: NSSize(width: 400, height: 520)) {
            AccountAddModalView(
                onDismiss: { [weak self] in self?.closeAuxiliaryWindow() },
                onSave: { [weak self] draft in
                    guard let self else { return }
                    try await self.store.addAccount(draft)
                },
                onProbe: { [weak self] draft in
                    guard let self else { throw ProviderError.transport }
                    return try await self.store.probe(draft)
                }
            )
        }
    }

    private func showSettingsWindow() {
        presentAuxiliaryWindow(title: "Relay 设置", size: NSSize(width: 400, height: 520)) {
            SettingsWindowView(
                initialSettings: self.store.settings,
                initialGlobalShortcutConfiguration: GlobalShortcutConfigurationStore.load(),
                onApplyGlobalShortcut: self.onApplyGlobalShortcut,
                syncStatus: self.store.syncStatus,
                syncConflictReport: self.store.syncConflictReport,
                onResolveSyncConflict: { [weak self] decision in
                    self?.store.resolveSyncConflict(decision)
                },
                onClose: { [weak self] in self?.closeAuxiliaryWindow() },
                onSave: { [weak self] settings in self?.store.updateSettings(settings) }
            )
        }
    }

    private func showAccountDetailWindow(
        account: AccountModel,
        spendPoints: [DailySpendPoint],
        modelUsages: [ModelUsageItem]
    ) {
        presentAuxiliaryWindow(title: "账号详情", size: NSSize(width: 400, height: 520)) {
            AccountDetailView(
                account: account,
                spendPoints: spendPoints,
                modelUsages: modelUsages,
                onClose: { [weak self] in self?.closeAuxiliaryWindow() }
            )
        }
    }

    private func showAccountEditWindow(account: AccountModel) {
        presentAuxiliaryWindow(title: "编辑账号", size: NSSize(width: 400, height: 520)) {
            AccountEditModalView(
                account: account,
                onDismiss: { [weak self] in self?.closeAuxiliaryWindow() },
                onSave: { [weak self] name, threshold, credential in
                    guard let self, let id = UUID(uuidString: account.id) else { return }
                    try await self.store.updateAccount(
                        accountID: id,
                        displayName: name,
                        lowBalanceThreshold: threshold,
                        replacementCredential: credential
                    )
                }
            )
        }
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === auxiliaryWindowController?.window else { return }
        auxiliaryWindowController = nil
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let balance: String
        if let amount = store.balanceTotalCNY.value?.amount {
            balance = RelayNumberFormatter.money(amount, currency: store.settings.baseCurrency)
        } else {
            balance = "--"
        }
        let today: String? = {
            guard store.settings.showTodayInMenuBar,
                  store.todaySpendTotalCNY.isComplete,
                  let amount = store.todaySpendTotalCNY.value?.amount else { return nil }
            return "今日 \(RelayNumberFormatter.money(amount, currency: store.settings.baseCurrency))"
        }()
        let suffix = today.map { " · \($0)" } ?? ""
        button.title = "⚡ \(balance)\(suffix)"
        button.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        button.image = nil
        if store.isRefreshing {
            button.title = "↻ \(balance)\(suffix)"
        } else if store.hasAnyWarning || store.hasLowBalance {
            button.title = "⚠︎ \(balance)\(suffix)"
        }

        let fixedWidth = UserDefaults.standard.object(forKey: "fixedMenuBarWidth") as? Bool ?? true
        statusItem.length = fixedWidth ? fixedStatusItemLength : NSStatusItem.variableLength
    }
}
