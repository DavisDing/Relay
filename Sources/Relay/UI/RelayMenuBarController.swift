import AppKit
import Combine
import SwiftUI

/// AppKit shell for the menu-bar popover and its auxiliary pages.
///
/// The dashboard stays a lightweight NSPopover, while forms and detail pages
/// use borderless key windows with the same panel surface as the dashboard.
/// SwiftUI sheets hosted directly by an NSPopover are unreliable in accessory
/// applications: the transient popover can close or lose key-window status as
/// soon as a sheet is interacted with.
private final class RelayPanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct RelayAuxiliaryPanel<Content: View>: View {
    private let size: CGSize
    private let content: Content

    init(size: CGSize, @ViewBuilder content: () -> Content) {
        self.size = size
        self.content = content()
    }

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

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
    private let fixedStatusItemLength: CGFloat = 70

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
        statusItem.button?.cell?.usesSingleLineMode = true
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
        pendingDashboardReturn = nil
        guard let button = statusItem.button else { return }
        // Restore the existing hosting controller, including SwiftUI form state.
        // Only an explicit cancel/save/close may destroy a draft.
        if let window = auxiliaryWindowController?.window {
            if window.isVisible && NSApp.isActive && window.isKeyWindow {
                window.orderOut(nil)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
            }
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    public func close() {
        pendingDashboardReturn = nil
        if popover.isShown { popover.performClose(nil) }
        auxiliaryWindowController?.window?.orderOut(nil)
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

    // Every auxiliary page returns home on explicit close; hiding remains separate.
    private var pendingDashboardReturn: UUID?

    private func presentAuxiliaryWindow<Content: View>(
        title: String,
        size: NSSize,
        @ViewBuilder content: () -> Content
    ) {
        // Capture the dashboard content frame before dismissing its popover.
        let anchor: NSRect? = popover.contentViewController.map { controller in
            let view = controller.view
            return view.window?.convertToScreen(view.convert(view.bounds, to: nil)) ?? .zero
        }
        let screen = statusItem.button?.window?.screen
        close()
        // Replacing a page is not user navigation back to the dashboard.
        // Detach before closing so the old window cannot schedule a return home.
        auxiliaryWindowController?.window?.delegate = nil
        auxiliaryWindowController?.close()
        auxiliaryWindowController = nil

        let window = RelayPanelWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentViewController = NSHostingController(
            rootView: RelayAuxiliaryPanel(size: size) {
                AnyView(content())
            }
        )
        window.delegate = self

        let controller = NSWindowController(window: window)
        auxiliaryWindowController = controller
        if let screen {
            let visible = screen.visibleFrame
            let buttonFrame = statusItem.button?.window?.frame ?? visible
            let contentTop = anchor.flatMap { $0 == .zero ? nil : $0 }
            let rect = NSRect(
                x: contentTop?.minX ?? (buttonFrame.midX - size.width / 2),
                y: (contentTop?.maxY ?? visible.maxY) - size.height,
                width: size.width, height: size.height
            )
            var frame = window.frameRect(forContentRect: rect)
            frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
            frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
            window.setFrame(frame, display: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func closeAuxiliaryWindow() {
        // windowWillClose owns cleanup and the common return-to-home behavior.
        auxiliaryWindowController?.close()
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
                onSave: { [weak self] name, threshold, credential, rateUpdate in
                    guard let self, let id = UUID(uuidString: account.id) else { return }
                    try await self.store.updateAccount(
                        accountID: id,
                        displayName: name,
                        lowBalanceThreshold: threshold,
                        replacementCredential: credential,
                        manualUSDToCNY: rateUpdate
                    )
                }
            )
        }
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === auxiliaryWindowController?.window else { return }
        auxiliaryWindowController = nil
        let request = UUID()
        pendingDashboardReturn = request
        // Wait for AppKit to finish closing any auxiliary page, not just details.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingDashboardReturn == request else { return }
            self.pendingDashboardReturn = nil
            // A later hide/toggle/page change cancels this pending return.
            guard self.auxiliaryWindowController == nil,
                  !self.popover.isShown, let button = self.statusItem.button else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let total = store.todaySpendTotalCNY
        let presentation = MenuBarStatusPresentation(
            todaySpendAmount: total.isComplete && store.settings.showTodayInMenuBar ? total.value?.amount : nil,
            isRefreshing: store.isRefreshing,
            hasWarning: store.hasAnyWarning || store.hasLowBalance
        )
        let image = NSImage(systemSymbolName: presentation.symbolName, accessibilityDescription: presentation.statusDescription)
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = nil
        button.imagePosition = presentation.title.isEmpty ? .imageOnly : .imageLeading
        button.title = presentation.title
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.toolTip = presentation.toolTip
        button.setAccessibilityLabel(presentation.toolTip)
        let fixedWidth = UserDefaults.standard.object(forKey: "fixedMenuBarWidth") as? Bool ?? true
        // Keep Relay accessible, but don't reserve empty metric space or show --.
        statusItem.length = presentation.title.isEmpty ? NSStatusItem.squareLength
            : (fixedWidth ? fixedStatusItemLength : NSStatusItem.variableLength)
    }
}
