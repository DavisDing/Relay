import SwiftUI

@MainActor
struct NotificationStatusPanel: View {
    @ObservedObject private var status = NotificationStatusService.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsHint(status.authorizationText)
            SettingsActionRow {
                Button("检查权限") { Task { await status.refresh() } }
                    .disabled(status.isTesting)
                Button("测试通知") { Task { await status.test() } }
                    .buttonStyle(RelaySecondaryCapsuleButtonStyle(isLoading: status.isTesting))
                    .disabled(status.isTesting)
            }
            if let message = status.deliveryMessage {
                Text(message).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.controlSize(.small).task { await status.refresh() }
    }
}
