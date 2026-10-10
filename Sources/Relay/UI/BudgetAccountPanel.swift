import SwiftUI

/// Complements the detail view without changing the existing monetary cards.
public struct BudgetAccountPanel: View {
    public let budget: MoneyValue?
    public let snapshot: ProviderSnapshot?
    public let accountID: UUID
    public let provider: ProviderKind

    public init(budget: MoneyValue?, snapshot: ProviderSnapshot?, accountID: UUID, provider: ProviderKind) {
        self.budget = budget; self.snapshot = snapshot; self.accountID = accountID; self.provider = provider
    }

    public var body: some View {
        let state = BudgetService.progress(budget: budget, snapshot: snapshot, accountID: accountID,
                                          calendar: BudgetService.calendar(for: provider))
        if state != .disabled {
            VStack(alignment: .leading, spacing: 7) {
                Text("本月预算").font(.system(size: 13, weight: .semibold))
                switch state {
                case .disabled: EmptyView()
                case .unavailable(let message):
                    Text(message).font(.caption).foregroundStyle(.secondary)
                case let .known(spend, budget, ratio):
                    HStack {
                        Text("\(RelayNumberFormatter.money(spend.amount, currency: spend.currency)) / \(RelayNumberFormatter.money(budget.amount, currency: budget.currency))")
                        Spacer()
                        Text(RelayNumberFormatter.percent(ratio))
                            .foregroundStyle(ratio >= 1 ? .red : ratio >= Decimal(string: "0.8")! ? .orange : .secondary)
                    }.font(.caption).monospacedDigit()
                    if snapshot?.freshness != .fresh {
                        Text("上次成功数据，仅供参考；刷新成功后再判断提醒。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(max(NSDecimalNumber(decimal: ratio).doubleValue, 0), 1))
                        .tint(ratio >= 1 ? .red : .accentColor)
                    Text("开启预算提醒后，达到 80% 和 100% 时通知。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(11).relayGlassTile(cornerRadius: 10)
        }
    }
}
