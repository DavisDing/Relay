import SwiftUI
import AppKit

@MainActor
struct StorageRecoveryView: View {
    @ObservedObject var store: RelayStore
    let onClose: () -> Void
    @State private var entries: [LocalBackupEntry] = []
    @State private var preview: StorageRecoveryPreview?
    @State private var busy = false
    @State private var message: String?
    private let backups = LocalBackupService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("从备份恢复损坏数据").font(.headline); Spacer(); Button("关闭", action: onClose).buttonStyle(RelayTextButtonStyle()).disabled(busy) }
            Text("恢复前会保留损坏原文件。备份不含凭据，恢复后请重新录入账户凭据；同步保持关闭。")
                .font(.caption).foregroundStyle(.secondary)
            if entries.isEmpty { Text("未找到有效备份，请检查原备份目录授权。") }
            HStack {
                Button("刷新备份列表") { Task { await load() } }
                Button("重新授权原备份目录…") { authorize() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        HStack {
                            Text(date(entry.createdAt))
                            Spacer()
                            Button("预览") {
                                busy = true
                                Task {
                                    defer { busy = false }
                                    do { preview = try await store.previewStorageRecovery(entry); message = nil }
                                    catch { message = error.localizedDescription }
                                }
                            }
                        }
                    }
                }
            }
            if let preview {
                Text("将恢复 \(preview.backup.data.accounts.count) 个账户、\(preview.backup.data.dailyUsage.count) 条历史，替换损坏数据。")
                Button("确认恢复并保留原文件") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await store.restoreDamagedStorage(preview); onClose() }
                        catch { message = error.localizedDescription; self.preview = nil }
                    }
                }.buttonStyle(RelayPrimaryCapsuleButtonStyle(isLoading: busy))
            }
            if busy { ProgressView() }
            if let message { Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(20).frame(width: RelayVisualStyle.panelWidth, height: 380)
            .relayPanelSurface(cornerRadius: 14).disabled(busy).task { await load() }
    }
    private func load() async {
        do { entries = try await backups.list(); message = nil }
        catch { entries = []; message = error.localizedDescription }
    }
    private func authorize() {
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.title = "重新选择原备份的父目录"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        Task {
            do { try await backups.renewDirectoryAuthorization(url); await load() }
            catch { message = error.localizedDescription }
        }
    }
    private func date(_ value: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyyMMdd HH:mm:ss"
        return formatter.string(from: value)
    }
}
