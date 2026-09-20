import Foundation
import AppKit
import Carbon.HIToolbox

/// The actions that Relay exposes to the global shortcut layer.
public enum GlobalShortcutAction: String, Codable, CaseIterable, Equatable, Sendable {
    case togglePopover
    case refreshAll
}

/// Local-only persistence for shortcut bindings. The configuration contains
/// key codes and modifier flags only; it never stores credentials or sync data.
public enum GlobalShortcutConfigurationStore {
    public static let defaultsKey = "relay.globalShortcutConfiguration.v1"

    public static func load(from defaults: UserDefaults = .standard) -> GlobalShortcutConfiguration {
        guard let data = defaults.data(forKey: defaultsKey),
              let configuration = try? JSONDecoder().decode(GlobalShortcutConfiguration.self, from: data) else {
            return GlobalShortcutConfiguration()
        }
        return configuration
    }

    public static func save(
        _ configuration: GlobalShortcutConfiguration,
        to defaults: UserDefaults = .standard
    ) throws {
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: defaultsKey)
    }
}

/// A small, persistence-safe modifier representation. Values intentionally match
/// Carbon's event-hot-key modifier flags so the model can cross the service boundary
/// without carrying AppKit event objects.
public struct GlobalShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let command = GlobalShortcutModifiers(rawValue: UInt32(cmdKey))
    public static let shift = GlobalShortcutModifiers(rawValue: UInt32(shiftKey))
    public static let option = GlobalShortcutModifiers(rawValue: UInt32(optionKey))
    public static let control = GlobalShortcutModifiers(rawValue: UInt32(controlKey))
}

/// A physical macOS virtual key code plus its modifier flags.
///
/// The service accepts key codes in the inclusive range 0...127, which is the
/// range used by macOS virtual key codes. It deliberately does not attempt to
/// translate localized keyboard characters into key codes.
public struct GlobalShortcutBinding: Codable, Equatable, Hashable, Sendable {
    public let keyCode: UInt32
    public let modifiers: GlobalShortcutModifiers

    public init(keyCode: UInt32, modifiers: GlobalShortcutModifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var isValid: Bool {
        (0...127).contains(Int(keyCode))
    }
}

/// The two independent shortcuts can be configured separately or left unset.
public struct GlobalShortcutConfiguration: Codable, Equatable, Sendable {
    public var togglePopover: GlobalShortcutBinding?
    public var refreshAll: GlobalShortcutBinding?

    public init(
        togglePopover: GlobalShortcutBinding? = nil,
        refreshAll: GlobalShortcutBinding? = nil
    ) {
        self.togglePopover = togglePopover
        self.refreshAll = refreshAll
    }

    public var isEmpty: Bool {
        togglePopover == nil && refreshAll == nil
    }

    public func binding(for action: GlobalShortcutAction) -> GlobalShortcutBinding? {
        switch action {
        case .togglePopover: return togglePopover
        case .refreshAll: return refreshAll
        }
    }
}

public enum GlobalShortcutDisableReason: String, Codable, Equatable, Sendable {
    case notConfigured
    case unsupportedEnvironment
}

public enum GlobalShortcutError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case invalidBinding(action: GlobalShortcutAction)
    case duplicateBinding
    case conflict
    case registrationFailed(status: Int32)

    public var description: String {
        switch self {
        case let .invalidBinding(action):
            return "Invalid global shortcut binding for \(action.rawValue)."
        case .duplicateBinding:
            return "The two global shortcuts use the same key combination."
        case .conflict:
            return "The global shortcut is already registered by another application."
        case let .registrationFailed(status):
            return "Global shortcut registration failed (status \(status))."
        }
    }
}

public enum GlobalShortcutRegistrationOutcome: Equatable, Sendable {
    case registered(actions: Set<GlobalShortcutAction>)
    case disabled(reason: GlobalShortcutDisableReason)
    case failed(GlobalShortcutError)

    public var isRegistered: Bool {
        if case .registered = self { return true }
        return false
    }
}

/// A platform runtime used by GlobalShortcutService. The protocol keeps Carbon
/// and AppKit registration details out of the business contract and allows the
/// contract tests to use an entirely offline fake runtime.
public protocol GlobalShortcutRuntime: AnyObject {
    var isPackagedApplication: Bool { get }

    func register(
        binding: GlobalShortcutBinding,
        action: GlobalShortcutAction,
        handler: @escaping () -> Void
    ) throws

    func unregisterAll()
}

/// Main-actor service intended to be owned by the app shell. It never blocks on
/// registration and treats every registration failure as a recoverable outcome.
@MainActor
public final class GlobalShortcutService {
    public private(set) var outcome: GlobalShortcutRegistrationOutcome = .disabled(reason: .notConfigured)
    public private(set) var lastTriggeredAction: GlobalShortcutAction?

    private let runtime: GlobalShortcutRuntime
    private var configuredActions: Set<GlobalShortcutAction> = []
    private var onAction: ((GlobalShortcutAction) -> Void)?

    public init(
        runtime: GlobalShortcutRuntime = CarbonGlobalShortcutRuntime(),
        onAction: ((GlobalShortcutAction) -> Void)? = nil
    ) {
        self.runtime = runtime
        self.onAction = onAction
    }

    /// Replaces the current registration atomically. If any configured action
    /// fails, all actions registered during this call are removed and the
    /// result is `.failed`; no partial success is reported.
    @discardableResult
    public func start(configuration: GlobalShortcutConfiguration) -> GlobalShortcutRegistrationOutcome {
        stop()

        guard !configuration.isEmpty else {
            outcome = .disabled(reason: .notConfigured)
            return outcome
        }

        guard runtime.isPackagedApplication else {
            outcome = .disabled(reason: .unsupportedEnvironment)
            return outcome
        }

        for action in GlobalShortcutAction.allCases {
            guard let binding = configuration.binding(for: action) else { continue }
            guard binding.isValid else {
                outcome = .failed(.invalidBinding(action: action))
                return outcome
            }
        }

        if let toggle = configuration.togglePopover,
           let refresh = configuration.refreshAll,
           toggle == refresh {
            outcome = .failed(.duplicateBinding)
            return outcome
        }

        var registeredActions = Set<GlobalShortcutAction>()
        do {
            for action in GlobalShortcutAction.allCases {
                guard configuration.binding(for: action) != nil else { continue }
                try runtime.register(binding: configuration.binding(for: action)!, action: action) { [weak self] in
                    self?.handle(action)
                }
                registeredActions.insert(action)
            }
        } catch let error as GlobalShortcutError {
            runtime.unregisterAll()
            configuredActions.removeAll()
            outcome = .failed(error)
            return outcome
        } catch {
            runtime.unregisterAll()
            configuredActions.removeAll()
            outcome = .failed(.registrationFailed(status: -1))
            return outcome
        }

        configuredActions = registeredActions
        outcome = .registered(actions: registeredActions)
        return outcome
    }

    /// Removes all registered shortcuts. Calling this repeatedly is safe.
    public func stop() {
        runtime.unregisterAll()
        configuredActions.removeAll()
        if !outcome.isRegistered {
            return
        }
        outcome = .disabled(reason: .notConfigured)
    }

    public func setActionHandler(_ handler: ((GlobalShortcutAction) -> Void)?) {
        onAction = handler
    }

    private func handle(_ action: GlobalShortcutAction) {
        guard configuredActions.contains(action) else { return }
        lastTriggeredAction = action
        onAction?(action)
    }
}

/// Carbon-backed implementation used by the packaged Relay app. A SwiftPM
/// executable or test binary is deliberately rejected before touching Carbon,
/// so development builds cannot claim that a shortcut was registered.
public final class CarbonGlobalShortcutRuntime: GlobalShortcutRuntime {
    private final class RegistrationState {
        let eventHotKeyRef: EventHotKeyRef
        let handler: () -> Void

        init(eventHotKeyRef: EventHotKeyRef, handler: @escaping () -> Void) {
            self.eventHotKeyRef = eventHotKeyRef
            self.handler = handler
        }
    }

    private var eventHandlerRef: EventHandlerRef?
    private var registrations: [UInt32: RegistrationState] = [:]
    private var nextID: UInt32 = 1

    public init() {}

    public var isPackagedApplication: Bool {
        Bundle.main.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }

    public func register(
        binding: GlobalShortcutBinding,
        action: GlobalShortcutAction,
        handler: @escaping () -> Void
    ) throws {
        guard isPackagedApplication else {
            throw GlobalShortcutError.registrationFailed(status: -1)
        }
        guard binding.isValid else {
            throw GlobalShortcutError.invalidBinding(action: action)
        }

        try installEventHandlerIfNeeded()

        let id = nextID
        nextID &+= 1
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers.rawValue,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else {
            if status == eventHotKeyExistsErr {
                throw GlobalShortcutError.conflict
            }
            throw GlobalShortcutError.registrationFailed(status: Int32(status))
        }

        registrations[id] = RegistrationState(eventHotKeyRef: hotKeyRef, handler: handler)
    }

    public func unregisterAll() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.eventHotKeyRef)
        }
        registrations.removeAll()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    deinit {
        unregisterAll()
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandlerRef == nil else { return }

        var eventSpec = EventTypeSpec(eventClass: UInt32(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var installedHandler: EventHandlerRef?
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventSpec,
            userData,
            &installedHandler
        )
        guard status == noErr else {
            throw GlobalShortcutError.registrationFailed(status: Int32(status))
        }
        eventHandlerRef = installedHandler
    }

    private static let signature: OSType = {
        let bytes: [UInt8] = [0x52, 0x4C, 0x59, 0x4B] // RLYK
        return OSType(bytes[0]) << 24 | OSType(bytes[1]) << 16 | OSType(bytes[2]) << 8 | OSType(bytes[3])
    }()

    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        let runtime = Unmanaged<CarbonGlobalShortcutRuntime>.fromOpaque(userData).takeUnretainedValue()
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == signature,
              let registration = runtime.registrations[hotKeyID.id] else {
            return OSStatus(eventNotHandledErr)
        }

        registration.handler()
        return noErr
    }
}
