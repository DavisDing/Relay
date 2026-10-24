import SwiftUI
import AppKit

@MainActor
struct SettingsShortcutsPage: View {
    @Binding var showGlobalShortcutSettings: Bool
    @Binding var launchAtLoginEnabled: Bool
    @Binding var launchAtLoginError: String?
    @Binding var enableICloudFileSync: Bool
    @Binding var iCloudDirectoryURL: URL?
    @Binding var iCloudDirectoryError: String?
    let initialGlobalShortcutConfiguration: GlobalShortcutConfiguration
    let onApplyGlobalShortcut: ((GlobalShortcutConfiguration) -> GlobalShortcutRegistrationOutcome)?

    var body: some View {
        SettingsPageScroll {
            SettingsSection("全局快捷键") {
                SettingsHint("显示 / 隐藏面板，或刷新全部账户。配置仅保存在本机，无需辅助功能权限。")
                if onApplyGlobalShortcut != nil {
                    SettingsActionRow {
                        Button("配置快捷键…") { showGlobalShortcutSettings = true }
                    }
                } else {
                    SettingsHint("当前运行环境未提供全局快捷键注册能力。")
                }
            }

            Divider().opacity(0.4)
            SettingsSection("通知权限") {
                NotificationStatusPanel()
                SettingsHint("低余额和月预算开关分别在「常规」「数据」中设置；系统授权不等于已开启这些提醒。")
            }

            Divider().opacity(0.4)
            SettingsSection("登录项") {
                SettingsToggleRow(title: "登录时自动启动", detail: "使用 macOS 系统登录项。", isOn: Binding(
                    get: { launchAtLoginEnabled }, set: { setLaunchAtLogin($0) }
                ))
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.system(size: 10)).foregroundStyle(.red)
                }
            }

            Divider().opacity(0.4)
            SettingsSection("iCloud 目录权限") {
                SettingsHint(iCloudDirectoryURL?.path ?? "尚未授权同步目录。")
                    .textSelection(.enabled)
                SettingsHint("请选择 iCloud Drive/Documents/Relay；只同步非秘密数据，不同步凭据。")
                SettingsActionRow {
                    Button(iCloudDirectoryURL == nil ? "选择同步文件夹…" : "更换 / 重新授权…") { chooseICloudDirectory() }
                }
                if let iCloudDirectoryError {
                    Text(iCloudDirectoryError).font(.system(size: 10)).foregroundStyle(.red)
                }
            }

            Divider().opacity(0.4)
            SettingsBackupDirectoryPanel()
        }
        .sheet(isPresented: $showGlobalShortcutSettings) {
            if let onApplyGlobalShortcut {
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
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginService.setEnabled(enabled)
            launchAtLoginEnabled = enabled
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "无法更新登录项：\(error.localizedDescription)"
        }
    }

    private func chooseICloudDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 Relay iCloud 同步文件夹"
        panel.message = "请选择 iCloud Drive/Documents/Relay 文件夹。Relay 只会在此文件夹中写入不含凭据的同步文件。"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileSyncService.setSyncDirectory(url)
            iCloudDirectoryURL = FileSyncService.configuredDirectoryURL()
            iCloudDirectoryError = nil
            if iCloudDirectoryURL != nil { enableICloudFileSync = true }
        } catch { iCloudDirectoryError = error.localizedDescription }
    }
}
