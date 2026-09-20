import SwiftUI
import AppKit

@main
struct RelayApp: App {
    @StateObject private var store: RelayStore
    private let menuBarController: RelayMenuBarController
    private let globalShortcutService: GlobalShortcutService

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

        NSApplication.shared.setActivationPolicy(.accessory)
        let initialConfiguration = GlobalShortcutConfigurationStore.load()
        let resolvedService = GlobalShortcutService()
        weak var controller: RelayMenuBarController?
        resolvedService.setActionHandler { [weak resolvedStore] action in
            switch action {
            case .togglePopover:
                controller?.toggle()
            case .refreshAll:
                Task { @MainActor in
                    await resolvedStore?.refreshAll(forceRateRefresh: true)
                }
            }
        }
        let resolvedController = RelayMenuBarController(
            store: resolvedStore,
            initialGlobalShortcutConfiguration: initialConfiguration,
            onApplyGlobalShortcut: { configuration in
                let outcome = resolvedService.start(configuration: configuration)
                switch outcome {
                case .registered, .disabled:
                    try? GlobalShortcutConfigurationStore.save(configuration)
                case .failed:
                    break
                }
                return outcome
            }
        )
        controller = resolvedController
        self.menuBarController = resolvedController
        self.globalShortcutService = resolvedService
        _ = resolvedService.start(configuration: initialConfiguration)
    }

    var body: some Scene {
        // The visible app surface is owned by RelayMenuBarController. A hidden
        // settings scene keeps the SwiftUI App lifecycle alive without adding a
        // second user-facing window.
        Settings {
            EmptyView()
        }
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
