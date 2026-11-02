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
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("分组名称").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    TextField("可选，例如：生产、开发", text: $groupName).relayFormField()
                }
                Toggle("置顶", isOn: $isPinned).font(.system(size: 11))
                    .toggleStyle(.switch).controlSize(.mini)
                    .frame(height: RelayVisualStyle.inputHeight)
            }
            if provider != .workbuddy2api {
                VStack(alignment: .leading, spacing: 4) {
                    Text("每月预算").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("留空关闭预算", text: $monthlyBudget).relayFormField()
                        Picker("预算币种", selection: $budgetCurrency) {
                            ForEach(Currency.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 90)
                    }
                    Text("按账户原币种填写；预算提醒可在设置中开启。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Text("此网关没有可靠的月消费，暂不支持月预算。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}
