import Foundation
import UserNotifications

struct NotificationStatusActions {
    let readStatus: () async -> String
    let requestPermission: () async throws -> Bool
    let submitSample: () async throws -> Void
    static let system = NotificationStatusActions(readStatus: {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return "系统权限：尚未授权"
        case .denied: return "系统权限：已拒绝，请在系统设置中允许 Relay 通知"
        case .authorized, .provisional, .ephemeral:
            return settings.alertSetting == .enabled ? "系统权限：允许通知" : "系统权限：已授权，横幅提醒未开启"
        @unknown default: return "系统权限：未知状态"
        }
    }, requestPermission: {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }, submitSample: {
        let content = UNMutableNotificationContent()
        content.title = "Relay 测试通知"
        content.body = "这是一条测试提醒，不影响低余额或预算通知记录。"
        content.sound = .default
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "relay.notification-test", content: content, trigger: nil))
    })
}

@MainActor
public final class NotificationStatusService: ObservableObject {
    public static let shared = NotificationStatusService()
    @Published public private(set) var authorizationText = "尚未检查系统权限"
    @Published public private(set) var deliveryMessage: String?
    @Published public private(set) var isTesting = false
    private var lastRealSubmissionFailed = false
    private let actions: NotificationStatusActions
    init(actions: NotificationStatusActions = .system) { self.actions = actions }

    public func refresh() async { authorizationText = await actions.readStatus() }

    public func test() async {
        guard !isTesting else { return }
        isTesting = true
        defer { isTesting = false }
        do {
            guard try await actions.requestPermission() else {
                deliveryMessage = "系统未允许通知，请在系统设置中检查。"; await refresh(); return
            }
            try await actions.submitSample()
            deliveryMessage = "测试请求已提交；是否展示还取决于系统横幅、专注模式等设置。"
        } catch { deliveryMessage = "通知提交失败，请检查系统通知设置后重试。" }
        await refresh()
    }

    func recordFailure() {
        lastRealSubmissionFailed = true
        deliveryMessage = "最近一次通知提交失败，将在后续刷新时重试。"
    }
    func recordSuccess() {
        if lastRealSubmissionFailed { deliveryMessage = "最近一次通知请求已提交。" }
        lastRealSubmissionFailed = false
    }
}
