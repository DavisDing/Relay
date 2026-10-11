import SwiftUI

@MainActor
struct ConsumptionOverviewView: View {
    @ObservedObject var store: RelayStore
    let onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("月度与分组消费").font(.headline)
                Spacer()
                Button("完成", action: onClose)
            }
            Text("按供应商的日历月份统计已记录消费，不代表完整账单。隐藏、停用及积分账户不参与；缺日不补零，币种分别展示。环比仅比较已结束的同期自然日。")
                .font(.caption).foregroundStyle(.secondary)
            let rows = store.consumptionOverview()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("本月分组").font(.subheadline.bold())
                    if rows.isEmpty { Text("暂无可统计账户").foregroundStyle(.secondary) }
                    ForEach(ConsumptionOverviewService.groups(rows)) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.name).font(.subheadline.bold())
                            Text(amounts(group.amounts))
                            Text("已记录 \(group.knownDays)/\(group.expectedDays) 个账户日；不同供应商月份边界可能不同")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).relayInsetSurface(cornerRadius: 10)
                    }
                    Text("账户明细").font(.subheadline.bold())
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.name).font(.subheadline.bold())
                            Text("本月已记录：" + amounts(row.month.amounts))
                            Text("覆盖 \(row.month.knownDays)/\(row.month.expectedDays) 日 · 上月已记录：" + amounts(row.previousMonth.amounts))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("上月覆盖 \(row.previousMonth.knownDays)/\(row.previousMonth.expectedDays) 日")
                                .font(.caption).foregroundStyle(.secondary)
                            if let change = row.changePercent {
                                Text("已结束自然日与上月同期比较：\(RelayNumberFormatter.decimal(change))%")
                                    .font(.caption)
                            } else {
                                Text("同口径完整数据不足，暂不显示环比").font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).relayInsetSurface(cornerRadius: 10)
                    }
                }
            }
        }.padding(20).frame(width: RelayVisualStyle.panelWidth, height: 480).relayPanelSurface(cornerRadius: 14)
    }
    private func amounts(_ values: [MoneyValue]) -> String {
        values.isEmpty ? "未知" : values.map { RelayNumberFormatter.money($0.amount, currency: $0.currency) }.joined(separator: " · ")
    }
}
