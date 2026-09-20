import SwiftUI

/// Standalone settings surface for the two Relay global shortcuts.
///
/// This view deliberately accepts an apply closure instead of reaching into
/// RelayStore. The app shell can persist the configuration and call
/// GlobalShortcutService.start(configuration:) in one transaction, then return
/// the actual registration outcome to this view.
public struct GlobalShortcutSettingsView: View {
    @State private var toggleEnabled: Bool
    @State private var toggleKeyCode: String
    @State private var toggleCommand: Bool
    @State private var toggleShift: Bool
    @State private var toggleOption: Bool
    @State private var toggleControl: Bool

    @State private var refreshEnabled: Bool
    @State private var refreshKeyCode: String
    @State private var refreshCommand: Bool
    @State private var refreshShift: Bool
    @State private var refreshOption: Bool
    @State private var refreshControl: Bool

    @State private var statusMessage: String?
    @State private var statusIsError = false

    private let onApply: (GlobalShortcutConfiguration) -> GlobalShortcutRegistrationOutcome
    private let onCancel: () -> Void

    public init(
        initialConfiguration: GlobalShortcutConfiguration = GlobalShortcutConfiguration(),
        onApply: @escaping (GlobalShortcutConfiguration) -> GlobalShortcutRegistrationOutcome,
        onCancel: @escaping () -> Void = {}
    ) {
        self.onApply = onApply
        self.onCancel = onCancel

        let toggle = initialConfiguration.togglePopover
        _toggleEnabled = State(initialValue: toggle != nil)
        _toggleKeyCode = State(initialValue: toggle.map { String($0.keyCode) } ?? "49")
        _toggleCommand = State(initialValue: toggle?.modifiers.contains(.command) ?? true)
        _toggleShift = State(initialValue: toggle?.modifiers.contains(.shift) ?? false)
        _toggleOption = State(initialValue: toggle?.modifiers.contains(.option) ?? false)
        _toggleControl = State(initialValue: toggle?.modifiers.contains(.control) ?? false)

        let refresh = initialConfiguration.refreshAll
        _refreshEnabled = State(initialValue: refresh != nil)
        _refreshKeyCode = State(initialValue: refresh.map { String($0.keyCode) } ?? "15")
        _refreshCommand = State(initialValue: refresh?.modifiers.contains(.command) ?? true)
        _refreshShift = State(initialValue: refresh?.modifiers.contains(.shift) ?? true)
        _refreshOption = State(initialValue: refresh?.modifiers.contains(.option) ?? false)
        _refreshControl = State(initialValue: refresh?.modifiers.contains(.control) ?? false)
    }

    public var body: some View {
        Form {
            Section {
                Text("快捷键只在打包为 .app 的 Relay 中注册。SwiftPM 命令行环境、未配置或注册失败时不会显示为已启用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            shortcutSection(
                title: "显示/隐藏面板",
                action: .togglePopover,
                enabled: $toggleEnabled,
                keyCode: $toggleKeyCode,
                command: $toggleCommand,
                shift: $toggleShift,
                option: $toggleOption,
                control: $toggleControl
            )

            shortcutSection(
                title: "刷新全部账户",
                action: .refreshAll,
                enabled: $refreshEnabled,
                keyCode: $refreshKeyCode,
                command: $refreshCommand,
                shift: $refreshShift,
                option: $refreshOption,
                control: $refreshControl
            )

            if let statusMessage {
                Label(statusMessage, systemImage: statusIsError ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(statusIsError ? .red : .green)
                    .font(.footnote)
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("应用并注册", action: apply)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 420)
    }

    @ViewBuilder
    private func shortcutSection(
        title: String,
        action: GlobalShortcutAction,
        enabled: Binding<Bool>,
        keyCode: Binding<String>,
        command: Binding<Bool>,
        shift: Binding<Bool>,
        option: Binding<Bool>,
        control: Binding<Bool>
    ) -> some View {
        Section(title) {
            Toggle("启用此快捷键", isOn: enabled)
            TextField("虚拟 key code（0–127）", text: keyCode)
                .textFieldStyle(.roundedBorder)
                .disabled(!enabled.wrappedValue)

            HStack {
                Toggle("⌘", isOn: command)
                Toggle("⇧", isOn: shift)
                Toggle("⌥", isOn: option)
                Toggle("⌃", isOn: control)
            }
            .toggleStyle(.button)
            .disabled(!enabled.wrappedValue)

            Text(action == .togglePopover ? "触发 togglePopover" : "触发 refreshAll")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func apply() {
        do {
            let configuration = try makeConfiguration()
            let result = onApply(configuration)
            switch result {
            case let .registered(actions):
                let names = actions.sorted { $0.rawValue < $1.rawValue }.map { $0.rawValue }.joined(separator: ", ")
                statusIsError = false
                statusMessage = "已注册：\(names)"
            case let .disabled(reason):
                statusIsError = reason != .notConfigured
                statusMessage = reason == .notConfigured ? "未配置快捷键" : "当前环境未打包为 .app，未注册快捷键"
            case let .failed(error):
                statusIsError = true
                statusMessage = error.description
            }
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func makeConfiguration() throws -> GlobalShortcutConfiguration {
        let toggle = try makeBinding(
            enabled: toggleEnabled,
            keyCode: toggleKeyCode,
            command: toggleCommand,
            shift: toggleShift,
            option: toggleOption,
            control: toggleControl,
            action: .togglePopover
        )
        let refresh = try makeBinding(
            enabled: refreshEnabled,
            keyCode: refreshKeyCode,
            command: refreshCommand,
            shift: refreshShift,
            option: refreshOption,
            control: refreshControl,
            action: .refreshAll
        )
        return GlobalShortcutConfiguration(togglePopover: toggle, refreshAll: refresh)
    }

    private func makeBinding(
        enabled: Bool,
        keyCode: String,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool,
        action: GlobalShortcutAction
    ) throws -> GlobalShortcutBinding? {
        guard enabled else { return nil }
        guard let parsedKeyCode = UInt32(keyCode), parsedKeyCode <= 127 else {
            throw SettingsInputError.invalidKeyCode(action: action)
        }

        var modifiers: GlobalShortcutModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return GlobalShortcutBinding(keyCode: parsedKeyCode, modifiers: modifiers)
    }

    private enum SettingsInputError: LocalizedError {
        case invalidKeyCode(action: GlobalShortcutAction)

        var errorDescription: String? {
            switch self {
            case let .invalidKeyCode(action):
                return "请输入 \(action.rawValue) 的 0–127 key code。"
            }
        }
    }
}
