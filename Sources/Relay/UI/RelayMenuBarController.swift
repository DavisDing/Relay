import AppKit
import Combine
import SwiftUI

/// AppKit shell for the menu-bar popover. Using an owned NSPopover gives the
/// global shortcut an actual open/close target instead of pretending that a
/// MenuBarExtra scene can be controlled through a private API.
@MainActor
public final class RelayMenuBarController: NSObject {
    private let store: RelayStore
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var storeObservation: AnyCancellable?
    private var globalMouseMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?

    public init(
        store: RelayStore,
        initialGlobalShortcutConfiguration: GlobalShortcutConfiguration = GlobalShortcutConfigurationStore.load(),
        onApplyGlobalShortcut: ((GlobalShortcutConfiguration) -> GlobalShortcutRegistrationOutcome)? = nil
    ) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleStatusItemClick(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.toolTip = "Relay（左键打开，右键显示菜单）"

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 400, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: MainPopoverView(
                store: store,
                initialGlobalShortcutConfiguration: initialGlobalShortcutConfiguration,
                onApplyGlobalShortcut: onApplyGlobalShortcut
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
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
        // NSPopover.transient normally handles this, but menu-bar accessory apps
        // can miss the normal resign-active path. Observe both application
        // deactivation and global mouse presses so a click in another app always
        // closes Relay's popover.
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
    }
}
