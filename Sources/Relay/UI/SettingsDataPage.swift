import SwiftUI

@MainActor
struct SettingsDataPage: View {
    @Binding var refreshIntervalMinutes: String
    @Binding var historyRetention: HistoryRetention
    @AppStorage("budgetNotificationsEnabled") private var budgetNotificationsEnabled = false

    var body: some View {
        SettingsPageScroll {
            VStack(alignment: .leading, spacing: 8) {
                Text("数据刷新")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Text("自动数据刷新频率：")
                        .font(.system(size: 12))
                    TextField("5", text: $refreshIntervalMinutes)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 58)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("自动刷新间隔")
                        .accessibilityHint("单位为分钟")
                    Text("分钟")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Text("刷新失败时保留上一份可用快照，不用 0 覆盖未知数据。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                Text("历史数据")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Picker("保留策略", selection: $historyRetention) {
                    Text("一月").tag(HistoryRetention.oneMonth)
                    Text("半年").tag(HistoryRetention.halfYear)
                    Text("一年").tag(HistoryRetention.oneYear)
                    Text("永久").tag(HistoryRetention.forever)
                }
                .pickerStyle(.segmented)
                Text("仅保存每日聚合数据，不长期保存原始请求日志。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                Text("月预算通知")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Toggle("月预算达到 80% / 100% 时通知", isOn: $budgetNotificationsEnabled)
                    .toggleStyle(.checkbox)
                Text("预算按账户原币计算；未知、币种不同或过期的月消费不会触发通知。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

}
