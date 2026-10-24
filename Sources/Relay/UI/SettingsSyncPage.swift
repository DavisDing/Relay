import SwiftUI

@MainActor
struct SettingsSyncPage: View {
    @State private var isResolving = false
    @Binding var enableICloudFileSync: Bool
    let iCloudDirectoryURL: URL?
    @Binding var showSyncConflict: Bool
    @Binding var syncConflictActionError: String?
    let syncStatus: SyncStatus
    let syncConflictReport: SyncConflictReport?
    let onResolveSyncConflict: ((SyncConflictDecision) async -> String?)?
    var transferActions: DataTransferActions? = nil
    var backupErrorMessage: String? = nil

    var body: some View {
        SettingsPageScroll {
            SettingsSection("iCloud 同步") {
                SettingsToggleRow(title: "启用文件同步", isOn: $enableICloudFileSync)
                    .disabled(iCloudDirectoryURL == nil && !enableICloudFileSync)
                HStack(spacing: 6) {
                    Image(systemName: syncStatus == .failed || syncStatus == .conflicted ? "exclamationmark.triangle" : "icloud")
                        .foregroundStyle(syncStatus == .failed || syncStatus == .conflicted ? Color.orange : Color.secondary)
                    Text(syncStatus.title).font(.system(size: 11))
                }
                SettingsHint(iCloudDirectoryURL.map { "目录：" + $0.lastPathComponent } ?? "请先在「快捷键」页授权同步目录。")
                SettingsHint("同步账户配置与聚合记录，不含凭据；异常不影响本机数据。")
                if syncConflictReport != nil {
                    SettingsActionRow {
                        Button("冲突详情…") { showSyncConflict = true }
                    }
                }
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

            if let backupErrorMessage {
                Text(backupErrorMessage).font(.footnote).foregroundStyle(.red)
            }
            if let transferActions {
                DataTransferPanel(actions: transferActions)
            }
        }
    }

}
