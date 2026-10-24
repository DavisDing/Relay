import SwiftUI

@MainActor
struct ConsumptionOverviewView: View {
    @ObservedObject var store: RelayStore
    let onClose: () -> Void
    @State private var daily = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("消费总览").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("完成", action: onClose)
                    .buttonStyle(RelayTextButtonStyle())
            }
            Text("按供应商日历统计当日或本月已记录消费；缺失数据不补零，币种分别展示。隐藏、停用及积分账户不参与。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("消费周期", selection: $daily) {
                Text("当日消费").tag(true)
                Text("月度消费").tag(false)
            }.pickerStyle(.segmented).labelsHidden()
            let rows = store.consumptionOverview()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(daily ? "当日分组" : "本月分组").font(.subheadline.bold())
                    if rows.isEmpty { Text("暂无可统计账户").foregroundStyle(.secondary) }
                    ForEach(ConsumptionOverviewService.groups(rows, daily: daily)) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.name).font(.subheadline.bold())
                            Text(amounts(group.amounts))
                            Text(daily ? "已记录 \(group.knownDays)/\(group.expectedDays) 个账户的当日消费" : "已记录 \(group.knownDays)/\(group.expectedDays) 个账户日")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).relayGlassTile()
                    }
                    Text("账户明细").font(.subheadline.bold())
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.name).font(.subheadline.bold())
                            if daily {
                                Text("当日已记录：" + amounts(row.today.amounts))
                                Text(row.today.knownDays == 1 ? "按供应商当日口径" : "当日消费未知")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
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
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).relayGlassTile()
                    }
                }
            }
        }.padding(16).frame(width: RelayVisualStyle.panelWidth, height: 480).relayPanelSurface()
    }
    private func amounts(_ values: [MoneyValue]) -> String {
        values.isEmpty ? "未知" : values.map { RelayNumberFormatter.money($0.amount, currency: $0.currency) }.joined(separator: " · ")
    }
}
