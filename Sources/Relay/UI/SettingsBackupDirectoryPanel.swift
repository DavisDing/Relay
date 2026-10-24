import SwiftUI
import AppKit

/// Directory authorization stays in the permissions tab; backup/restore stays in Sync.
@MainActor
struct SettingsBackupDirectoryPanel: View {
    var backups: LocalBackupService = .shared
    @State private var directoryPath: String?
    @State private var pendingMigration = false
    @State private var isBusy = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        SettingsSection("备份目录权限") {
            SettingsHint(directoryPath ?? "目录不可用，请重新选择或恢复默认目录。")
                .textSelection(.enabled)
            SettingsHint("所选文件夹内使用 RelayBackups 子目录；更换目录会先复制校验，再清理旧备份。授权只留本机。")
            SettingsActionRow {
                Button("恢复默认") { changeDirectory(to: nil) }
                Button("选择 / 重新授权…") { chooseDirectory() }
            }
            if pendingMigration {
                SettingsHint("有尚未完成的搬移。授权原目录或新目录后，到「同步」重试；有效副本会保留。")
                SettingsActionRow {
                    Button("授权搬移目录…") { authorizeMigration() }
                }
            }
            if isBusy { ProgressView("正在更新目录…").controlSize(.small) }
            if let message {
                Text(message).font(.system(size: 10))
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(isBusy)
        .task { await reload() }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 Relay 备份文件夹"
        panel.message = "Relay 将在此文件夹中建立 RelayBackups 子目录。现有备份将搬移到新目录，校验成功后清理原文件。"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        changeDirectory(to: parent)
    }

    private func changeDirectory(to parent: URL?) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let warning: String?
                if let parent { warning = try await backups.selectDirectory(parent) }
                else { warning = try await backups.resetDirectory() }
                message = warning ?? "备份目录已更新。"
                isError = warning != nil
                await reload()
            } catch { report(error); await reload() }
        }
    }

    private func authorizeMigration() {
        let panel = NSOpenPanel()
        panel.title = "选择未完成搬移的原目录或新目录的父文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await backups.authorizePendingMigration(url)
                message = "授权已更新，请到「同步」重试搬移。"
                isError = false
            } catch { report(error) }
            await reload()
        }
    }

    private func reload() async {
        pendingMigration = await backups.hasPendingMigration()
        do { directoryPath = try await backups.currentDirectoryURL().path }
        catch { directoryPath = nil; report(error) }
    }

    private func report(_ error: Error) { message = error.localizedDescription; isError = true }
}
