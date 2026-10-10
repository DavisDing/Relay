import SwiftUI

/// Retains the model name, full token count, cache-read ratio, and native cost
/// while adding filtering and insights for the fetched model breakdown.
public struct ModelAnalysisPanel: View {
    public let items: [ModelUsageItem]
    @State private var sort: ModelAnalysisSort = .spend
    @State private var topFive = false

    public init(items: [ModelUsageItem]) { self.items = items }

    public var body: some View {
        if !items.isEmpty {
            let analysis = ModelAnalysisService.analyze(items, sort: sort, topFive: topFive)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("模型消耗分析").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Picker("排序", selection: $sort) {
                        ForEach(ModelAnalysisSort.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 100)
                    Toggle("Top 5", isOn: $topFive).toggleStyle(.checkbox).font(.caption)
                }
                if analysis.hasUnknownSpend {
                    Text("部分模型消费未知，完整占比暂不可计算。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if analysis.hasMixedCurrencies {
                    Text("按原始币种分别排序，金额未跨币种换算；不显示整体占比。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text("单位成本为已获取消费 ÷ 总 Token × 100 万，仅描述当前明细，包含服务商返还的缓存等影响。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(analysis.rows) { row in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.item.modelName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                .truncationMode(.middle).help(row.item.modelName)
                            Text(row.item.tokenCount.map { RelayNumberFormatter.tokens($0) + " Token" } ?? "Token 未知")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .help("\(row.item.tokens) Token")
                                .accessibilityLabel("总 Token：\(row.item.tokens)")
                            Text(row.item.cacheHitRate.map { "缓存读取 " + RelayNumberFormatter.percent($0) } ?? "缓存读取 --")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .accessibilityLabel("缓存读取比例：" + (row.item.cacheHitRate.map(RelayNumberFormatter.percent) ?? "未知"))
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(row.item.cost.map { RelayNumberFormatter.money($0, currency: row.item.currency) } ?? "消费未知")
                                .font(.system(size: 11)).monospacedDigit()
                            Text(row.spendShare.map { "占比 " + RelayNumberFormatter.percent($0) } ?? "占比 --")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(row.costPerMillionTokens.map { RelayNumberFormatter.money($0.amount, currency: $0.currency) + " / 百万 Token" } ?? "单位成本 --")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }.padding(9).relayGlassTile(cornerRadius: 8)
                }
            }
        }
    }
}
