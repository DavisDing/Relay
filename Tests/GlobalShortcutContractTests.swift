import Foundation
import Darwin

private final class FakeGlobalShortcutRuntime: GlobalShortcutRuntime {
    var isPackagedApplication: Bool
    var shouldFailWith: GlobalShortcutError?
    private(set) var registerCalls: [(GlobalShortcutBinding, GlobalShortcutAction)] = []
    private var handlers: [GlobalShortcutAction: () -> Void] = [:]
    private(set) var unregisterAllCallCount = 0

    init(isPackagedApplication: Bool) {
        self.isPackagedApplication = isPackagedApplication
    }

    func register(
        binding: GlobalShortcutBinding,
        action: GlobalShortcutAction,
        handler: @escaping () -> Void
    ) throws {
        if let shouldFailWith { throw shouldFailWith }
        registerCalls.append((binding, action))
        handlers[action] = handler
    }

    func unregisterAll() {
        unregisterAllCallCount += 1
        handlers.removeAll()
    }

    func trigger(_ action: GlobalShortcutAction) {
        handlers[action]?()
    }
}

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
@MainActor
private enum GlobalShortcutContractTests {
    static func main() {
        testNotConfiguredDoesNotRegister()
        testUnpackagedEnvironmentDoesNotRegister()
        testInvalidBindingDoesNotRegister()
        testActionsAreDelivered()
        testRegistrationFailureIsNotSuccess()
        testRegistrationIsTransactional()
        testStopRemovesHandlers()
        print("GlobalShortcutContractTests: PASS")
    }

    private static let toggle = GlobalShortcutBinding(
        keyCode: 49,
        modifiers: [.command, .shift]
    )
    private static let refresh = GlobalShortcutBinding(
        keyCode: 15,
        modifiers: [.command, .option]
    )

    private static func testNotConfiguredDoesNotRegister() {
        let runtime = FakeGlobalShortcutRuntime(isPackagedApplication: true)
        let service = GlobalShortcutService(runtime: runtime)
        let result = service.start(configuration: GlobalShortcutConfiguration())

        require(result == .disabled(reason: .notConfigured), "empty configuration must be disabled")
        require(runtime.registerCalls.isEmpty, "empty configuration must not call runtime.register")
    }

    private static func testUnpackagedEnvironmentDoesNotRegister() {
        let runtime = FakeGlobalShortcutRuntime(isPackagedApplication: false)
        let service = GlobalShortcutService(runtime: runtime)
        let result = service.start(configuration: GlobalShortcutConfiguration(togglePopover: toggle))

        require(result == .disabled(reason: .unsupportedEnvironment), "unpackaged environment must be disabled")
        require(runtime.registerCalls.isEmpty, "unpackaged environment must not call runtime.register")
    }

    private static func testInvalidBindingDoesNotRegister() {
        let runtime = FakeGlobalShortcutRuntime(isPackagedApplication: true)
        let service = GlobalShortcutService(runtime: runtime)
        let result = service.start(configuration: GlobalShortcutConfiguration(
            togglePopover: GlobalShortcutBinding(keyCode: 128, modifiers: [.command])
        ))

        require(result == .failed(.invalidBinding(action: .togglePopover)), "invalid binding must fail explicitly")
        require(runtime.registerCalls.isEmpty, "invalid binding must not call runtime.register")
    }

    private static func testActionsAreDelivered() {
        let runtime = FakeGlobalShortcutRuntime(isPackagedApplication: true)
        var received: [GlobalShortcutAction] = []
        let service = GlobalShortcutService(runtime: runtime) { received.append($0) }
        let result = service.start(configuration: GlobalShortcutConfiguration(
            togglePopover: toggle,
            refreshAll: refresh
        ))

        require(result == .registered(actions: [.togglePopover, .refreshAll]), "both configured actions must register")
        runtime.trigger(.togglePopover)
        runtime.trigger(.refreshAll)
        require(received == [.togglePopover, .refreshAll], "registered actions must reach the handler")
        require(service.lastTriggeredAction == .refreshAll, "last triggered action must be observable")
    }

    private static func testRegistrationFailureIsNotSuccess() {
        let runtime = FakeGlobalShortcutRuntime(isPackagedApplication: true)
        runtime.shouldFailWith = .conflict
        let service = GlobalShortcutService(runtime: runtime)
        let result = service.start(configuration: GlobalShortcutConfiguration(togglePopover: toggle))

        require(result == .failed(.conflict), "runtime conflict must be surfaced as failure")
        require(!result.isRegistered, "runtime conflict must never report success")
    }

    private static func testRegistrationIsTransactional() {
        let runtime = FakeGlobalShortcutRuntime(isPackagedApplication: true)
        let service = GlobalShortcutService(runtime: runtime)

        let first = service.start(configuration: GlobalShortcutConfiguration(togglePopover: toggle))
        require(first.isRegistered, "first registration must succeed")

        runtime.shouldFailWith = .registrationFailed(status: 42)
        let second = service.start(configuration: GlobalShortcutConfiguration(
            togglePopover: toggle,
            refreshAll: refresh
        ))

        require(second == .failed(.registrationFailed(status: 42)), "second registration must expose its failure")
        require(runtime.unregisterAllCallCount >= 2, "replacement and rollback must unregister existing handlers")
    }

    private static func testStopRemovesHandlers() {
        let runtime = FakeGlobalShortcutRuntime(isPackagedApplication: true)
        var received: [GlobalShortcutAction] = []
        let service = GlobalShortcutService(runtime: runtime) { received.append($0) }
        _ = service.start(configuration: GlobalShortcutConfiguration(togglePopover: toggle))
        service.stop()
        runtime.trigger(.togglePopover)

        require(received.isEmpty, "stop must remove handlers")
        require(service.outcome == .disabled(reason: .notConfigured), "stop must leave a disabled outcome")
    }
}
