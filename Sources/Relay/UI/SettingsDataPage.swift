import SwiftUI

@MainActor
struct SettingsDataPage: View {
    @Binding var refreshIntervalMinutes: String
    @Binding var historyRetention: HistoryRetention
    @AppStorage("budgetNotificationsEnabled") private var budgetNotificationsEnabled = false
    let onManagePermissions: () -> Void

    var body: some View {
        SettingsPageScroll {
            SettingsSection("数据刷新") {
                HStack(spacing: 8) {
                    Text("自动刷新间隔")
                    Spacer()
                    TextField("5", text: $refreshIntervalMinutes)
                        .relayFormField()
                        .frame(width: 58)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("自动刷新间隔")
                        .accessibilityHint("单位为分钟")
                    Text("分钟").foregroundStyle(.secondary)
                }
                SettingsHint("刷新失败时保留上一份可用快照，不用 0 覆盖未知数据。")
            }

            Divider().opacity(0.4)
            SettingsSection("历史数据") {
                Picker("保留策略", selection: $historyRetention) {
                    Text("一月").tag(HistoryRetention.oneMonth)
                    Text("半年").tag(HistoryRetention.halfYear)
                    Text("一年").tag(HistoryRetention.oneYear)
                    Text("永久").tag(HistoryRetention.forever)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                SettingsHint("仅保存每日聚合数据，不长期保存原始请求日志。")
            }

            Divider().opacity(0.4)
            SettingsSection("月预算通知") {
                SettingsToggleRow(title: "月预算提醒", detail: "达到 80% / 100% 时通知。", isOn: $budgetNotificationsEnabled)
                SettingsHint("按账户原币计算；未知、币种不同或过期的月消费不会触发通知。")
                SettingsActionRow {
                    Button("通知权限…", action: onManagePermissions)
                }
            }
        }
    }
}
