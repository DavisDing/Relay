import SwiftUI

@MainActor
struct NotificationStatusPanel: View {
    @ObservedObject private var status = NotificationStatusService.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(status.authorizationText).font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                Button("检查系统权限") { Task { await status.refresh() } }
                Button("发送测试通知") { Task { await status.test() } }.disabled(status.isTesting)
                if status.isTesting { ProgressView().controlSize(.small) }
            }
            if let message = status.deliveryMessage {
                Text(message).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.controlSize(.small).task { await status.refresh() }
    }
}
