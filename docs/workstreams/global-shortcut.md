# Global Shortcut Workstream

## Scope

This workstream adds an independently integrable global shortcut service for the two confirmed Relay actions:

- `togglePopover`
- `refreshAll`

The service is intentionally not wired into `RelayApp`, `RelayStore`, or `SettingsWindowView` in this isolated change. The integration owner can connect the action callback to the app shell and persist the configuration without changing the service contract.

## Contract

### Configuration

```swift
GlobalShortcutConfiguration(
    togglePopover: GlobalShortcutBinding(keyCode: 49, modifiers: [.command, .shift]),
    refreshAll: GlobalShortcutBinding(keyCode: 15, modifiers: [.command, .option])
)
```

Each binding is optional. A key code must be in `0...127`; modifier flags are represented by `GlobalShortcutModifiers` and do not carry AppKit event objects across the contract.

### Service

```swift
@MainActor
let service = GlobalShortcutService(
    onAction: { action in
        switch action {
        case .togglePopover:
            // App shell toggles its menu-bar popover.
        case .refreshAll:
            // App shell starts its existing refresh operation.
        }
    }
)

let outcome = service.start(configuration: configuration)
service.stop()
```

`start` is transactional. If either configured action fails, all registrations created during that call are removed and the outcome is `.failed`; partial success is never reported.

`GlobalShortcutRuntime` is the platform boundary. Offline tests use a fake runtime, so contract tests do not need Carbon registration, Accessibility permissions, a second app target, network access, or supplier credentials.

## Registration outcomes

- `.disabled(.notConfigured)`: no shortcuts are configured.
- `.disabled(.unsupportedEnvironment)`: the runtime is not a packaged `.app` environment.
- `.registered(actions: ...)`: every configured action was registered.
- `.failed(...)`: invalid binding, duplicate binding, system conflict, or another runtime failure.

The Carbon implementation checks the `.app` bundle condition before registration. SwiftPM command-line builds and test binaries therefore cannot claim successful registration. A system conflict is surfaced as `.conflict`; other Carbon failures retain their status code.

## UI integration surface

`GlobalShortcutSettingsView` is a standalone SwiftUI form. It edits the two optional bindings and accepts an `onApply` closure returning the actual `GlobalShortcutRegistrationOutcome`. It does not persist settings or call `RelayStore` itself. The view currently uses explicit macOS virtual key codes (`0...127`) rather than pretending to provide localized key capture; a future app-shell integration may supply a key-capture control while preserving the service contract.

## Design assumptions

1. The first integration only needs one binding per action.
2. Both actions may be configured independently.
3. The same key combination cannot be assigned to both actions.
4. The service is owned by the main actor because its callback will drive AppKit/SwiftUI state.
5. Registration failure is recoverable and must not prevent Relay startup.
6. This isolated workstream does not change persistence, app lifecycle, or existing protected UI files.

## Offline verification

`Tests/GlobalShortcutContractTests.swift` is a dependency-light executable-style contract test. It can be compiled with `GlobalShortcutService.swift` alone and is intentionally not required by the existing `scripts/test-regressions.sh` script, which currently compiles the regression suite separately and does not include UI files.
