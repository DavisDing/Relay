import SwiftUI

@MainActor
struct SettingsShortcutsPage: View {
    @Binding var showGlobalShortcutSettings: Bool
    let initialGlobalShortcutConfiguration: GlobalShortcutConfiguration
    let onApplyGlobalShortcut: ((GlobalShortcutConfiguration) -> GlobalShortcutRegistrationOutcome)?

    var body: some View {
        SettingsPageScroll {
            VStack(alignment: .leading, spacing: 8) {
                Text("全局快捷键")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("在后台快速显示/隐藏面板，或刷新全部账户。快捷键配置仅保存在本机。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                if let onApplyGlobalShortcut {
                    Button("配置全局快捷键…") {
                        showGlobalShortcutSettings = true
                    }
                    .sheet(isPresented: $showGlobalShortcutSettings) {
                        GlobalShortcutSettingsView(
                            initialConfiguration: initialGlobalShortcutConfiguration,
                            onApply: { configuration in
                                let result = onApplyGlobalShortcut(configuration)
                                if result.isRegistered || configuration.isEmpty {
                                    try? GlobalShortcutConfigurationStore.save(configuration)
                                }
                                return result
                            },
                            onCancel: { showGlobalShortcutSettings = false }
                        )
                    }
                } else {
                    Text("当前运行环境未提供全局快捷键注册能力。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

}
