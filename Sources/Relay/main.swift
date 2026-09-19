import SwiftUI
import AppKit

@main
struct RelayApp: App {
    @StateObject private var store: RelayStore

    init() {
        let resolvedStore: RelayStore
        do {
            resolvedStore = try RelayStore.production()
        } catch {
            resolvedStore = RelayStore.unavailable(error)
        }
        _store = StateObject(wrappedValue: resolvedStore)

        #if DEBUG
        do { try BusinessLogicSelfCheck.run() } catch {
            assertionFailure("Business logic self-check failed: \(error)")
        }
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MainPopoverView(store: store)
        } label: {
            MenuBarStatusView(
                balanceText: store.balanceTotalCNY.value.map { "\(store.settings.baseCurrency.symbol)\($0.amount)" } ?? "--",
                todaySpendText: store.settings.showTodayInMenuBar && store.todaySpendTotalCNY.isComplete
                    ? store.todaySpendTotalCNY.value.map { "\(store.settings.baseCurrency.symbol)\($0.amount)" }
                    : nil,
                isRefreshing: store.isRefreshing,
                hasWarning: store.hasAnyWarning,
                isLowBalance: store.hasLowBalance,
                fixedWidth: true
            )
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出 Relay") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }
}
