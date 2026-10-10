import SwiftUI

/// Fields participate in the containing account form's existing Save action.
struct AccountPreferencesFields: View {
    @Binding var monthlyBudget: String
    @Binding var budgetCurrency: Currency
    @Binding var groupName: String
    @Binding var isPinned: Bool
    let provider: ProviderKind

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("分组与预算").font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("分组名称").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextField("可选，例如：生产、开发", text: $groupName).textFieldStyle(.roundedBorder)
            }
            Toggle("置顶账号", isOn: $isPinned).font(.system(size: 12))
            if provider != .workbuddy2api {
                VStack(alignment: .leading, spacing: 4) {
                    Text("每月预算").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("留空关闭预算", text: $monthlyBudget).textFieldStyle(.roundedBorder)
                        Picker("预算币种", selection: $budgetCurrency) {
                            ForEach(Currency.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 90)
                    }
                    Text("选择服务商月消费的原始币种；开启预算提醒后，达到 80% 和 100% 时通知。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Text("此网关没有可靠的月消费，暂不支持月预算。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}
