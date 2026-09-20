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
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.toolTip = "Relay"

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 430, height: 560)
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
        updateStatusItem()
    }

    deinit {
        storeObservation?.cancel()
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

    @objc private func togglePopover(_ sender: Any?) {
        toggle()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let balance: String
        if let amount = store.balanceTotalCNY.value?.amount {
            balance = "\(store.settings.baseCurrency.symbol)\(amount)"
        } else {
            balance = "--"
        }
        button.title = "⚡ \(balance)"
        button.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        button.image = nil
        if store.isRefreshing {
            button.title = "↻ \(balance)"
        } else if store.hasAnyWarning || store.hasLowBalance {
            button.title = "⚠︎ \(balance)"
        }
    }
}
