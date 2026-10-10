import SwiftUI
import AppKit

@MainActor
struct SettingsSyncPage: View {
    @State private var isResolving = false
    @Binding var enableICloudFileSync: Bool
    @Binding var iCloudDirectoryURL: URL?
    @Binding var iCloudDirectoryError: String?
    @Binding var showSyncConflict: Bool
    @Binding var syncConflictActionError: String?
    let syncStatus: SyncStatus
    let syncConflictReport: SyncConflictReport?
    let onResolveSyncConflict: ((SyncConflictDecision) async -> String?)?
    var transferActions: DataTransferActions? = nil
    var backupErrorMessage: String? = nil

    var body: some View {
        SettingsPageScroll {
            VStack(alignment: .leading, spacing: 8) {
                Text("同步状态")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                HStack {
                    Image(systemName: syncStatus == .failed || syncStatus == .conflicted ? "exclamationmark.triangle" : "checkmark.icloud")
                        .foregroundColor(syncStatus == .failed || syncStatus == .conflicted ? .orange : .secondary)
                    Text(syncStatus.title)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    if syncConflictReport != nil {
                        Button("查看详情…") { showSyncConflict = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                Text("同步异常不会阻断本机账号数据；冲突候选在用户决策前保留。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .sheet(isPresented: $showSyncConflict) {
                VStack(alignment: .leading, spacing: 8) {
                    SyncConflictView(
                        state: SyncConflictState(
                            status: syncStatus,
                            report: syncConflictReport,
                            localDataAvailable: true
                        ),
                        onDecision: { decision in
                            guard !isResolving else { return }
                            isResolving = true
                            Task { @MainActor in
                                let error = await onResolveSyncConflict?(decision)
                                isResolving = false
                                if let error { syncConflictActionError = error }
                                else { syncConflictActionError = nil; showSyncConflict = false }
                            }
                        },
                        onDismiss: { showSyncConflict = false }
                    )
                    .disabled(isResolving)
                    if isResolving { ProgressView("正在处理同步冲突…").padding(.horizontal, 20) }
                    if let syncConflictActionError {
                        Text(syncConflictActionError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 20)
                    }
                }
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                Text("多设备配置同步 (iCloud Drive 文件同步)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                Toggle(isOn: $enableICloudFileSync) {
                    Text("启用 iCloud Drive 文件同步")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.checkbox)
                .disabled(iCloudDirectoryURL == nil && !enableICloudFileSync)

                HStack(spacing: 8) {
                    Button(iCloudDirectoryURL == nil ? "选择同步文件夹…" : "更换同步文件夹…") {
                        chooseICloudDirectory()
                    }
                    if let iCloudDirectoryURL {
                        Text(iCloudDirectoryURL.lastPathComponent)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("尚未选择")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("📁 请在系统目录选择器中确认 iCloud Drive/Documents/Relay 文件夹")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("🔒 安全承诺: 仅同步非敏感元数据与聚合快照，Token 绝不同步！")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.green)
                    if let iCloudDirectoryError {
                        Text(iCloudDirectoryError)
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .relayInsetSurface(cornerRadius: 8)
            }

            if let backupErrorMessage {
                Text(backupErrorMessage).font(.footnote).foregroundStyle(.red)
            }
            if let transferActions {
                DataTransferPanel(actions: transferActions)
            }
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
            if iCloudDirectoryURL != nil {
                enableICloudFileSync = true
            }
        } catch {
            iCloudDirectoryError = error.localizedDescription
        }
    }}
