import SwiftUI

public enum ModelAnalysisScope {
    case dailySpend
    case processCredits
}

/// One aligned row per model, with an explicit reporting scope and unit.
public struct ModelAnalysisPanel: View {
    public let items: [ModelUsageItem]?
    public let dateLabel: String
    public let scope: ModelAnalysisScope
    public let processSince: Date?
    public let unavailableMessage: String
    @State private var sort: ModelAnalysisSort = .spend
    @State private var topFive = false

    public init(items: [ModelUsageItem]?, dateLabel: String = "今日",
                scope: ModelAnalysisScope = .dailySpend, processSince: Date? = nil,
                unavailableMessage: String = "该日期暂无可用模型明细。") {
        self.items = items
        self.dateLabel = dateLabel
        self.scope = scope
        self.processSince = processSince
        self.unavailableMessage = unavailableMessage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("模型消耗分析").font(.system(size: 13, weight: .semibold))
                Text(dateLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                if let items, !items.isEmpty {
                    Picker("排序", selection: $sort) {
                        ForEach(ModelAnalysisSort.allCases) {
                            Text(scope == .processCredits && $0 == .spend ? "积分" : $0.rawValue).tag($0)
                        }
                    }.labelsHidden().frame(width: 65).controlSize(.mini)
                    Toggle("Top 5", isOn: $topFive).toggleStyle(.checkbox).font(.system(size: 10))
                }
            }
            if scope == .processCredits {
                Text("网关全部模型累计，不随趋势日期切换")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help(processScopeDetail)
                    .accessibilityLabel(processScopeDetail)
            }
            if let items, !items.isEmpty {
                let analysis = ModelAnalysisService.analyze(items, sort: sort, topFive: topFive)
                ModelUsageColumns {
                    Text("模型").frame(maxWidth: .infinity, alignment: .leading)
                    column("总 Token")
                    column("缓存占比")
                    column(unitCostTitle)
                    column(spendTitle)
                }
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .help(scope == .processCredits
                    ? "积分/百万：本进程累计积分 ÷ 本进程总 Token × 100 万；未知值显示 --。"
                    : "费用/百万：当日消费 ÷ 当日总 Token × 100 万；未知值显示 --。")
                ForEach(analysis.rows) { row in
                    ModelUsageColumns {
                        Text(row.item.modelName).font(.system(size: 11, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading).help(row.item.modelName)
                        column(row.item.tokenCount.map(RelayNumberFormatter.tokens) ?? "--")
                            .help("总 Token：\(row.item.tokens)")
                            .accessibilityLabel("总 Token：\(row.item.tokens)")
                        column(row.item.cacheHitRate.map(RelayNumberFormatter.percent) ?? "--")
                            .accessibilityLabel("缓存占比：" + (row.item.cacheHitRate.map(RelayNumberFormatter.percent) ?? "未知"))
                        let unitCost = row.costPerMillionTokens.map { amountText($0.amount, currency: $0.currency) }
                        let spend = row.item.cost.map { amountText($0, currency: row.item.currency) }
                        column(unitCost ?? "--")
                            .help(unitCostTitle + "：" + (unitCost ?? "未知"))
                            .accessibilityLabel(unitCostTitle + "：" + (unitCost ?? "未知"))
                        column(spend ?? "--")
                            .help(spendTitle + "：" + (spend ?? "未知")
                                + "；" + shareTitle + (row.spendShare.map { "：" + RelayNumberFormatter.percent($0) } ?? "未知"))
                            .accessibilityLabel(spendTitle + "：" + (spend ?? "未知"))
                    }
                    .font(.system(size: 10)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 7)
                    .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                }
            } else {
                Text(items == nil ? unavailableMessage : scope == .processCredits
                    ? "网关暂无累计模型记录。" : "该日期没有模型消耗记录。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var unitCostTitle: String { scope == .processCredits ? "积分/百万" : "费用/百万" }
    private var spendTitle: String { scope == .processCredits ? "累计积分" : "当日消费" }
    private var shareTitle: String {
        scope == .processCredits ? "已获取模型累计积分占比" : "已获取模型消费占比"
    }
    private var processScopeDetail: String {
        let explanation = "网关全部模型的进程累计统计；网关重启后重新累计，不随趋势日期切换。"
        guard let processSince else { return explanation }
        return explanation + "统计起点：" + processSince.formatted(date: .numeric, time: .shortened)
    }
    private func amountText(_ amount: Decimal, currency: Currency) -> String {
        guard !amount.isNaN, amount >= 0 else { return "--" }
        return scope == .processCredits ? RelayNumberFormatter.decimal(amount)
            : RelayNumberFormatter.money(amount, currency: currency)
    }

    private func column(_ text: String) -> some View {
        Text(text).lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct ModelUsageColumns: Layout {
    private let spacing: CGFloat = 4
    // Keep the model identifier at two fifths of the row. Equal metric cells
    // and centered text give the header and numbers consistent visual spacing.
    private func widths(_ width: CGFloat) -> [CGFloat] {
        let available = max(0, width - spacing * 4)
        let modelWidth = min(available, max(0, width * 0.4))
        let metricWidth = (available - modelWidth) / 4
        return [modelWidth] + Array(repeating: metricWidth, count: 4)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 310
        let height = zip(subviews, widths(width)).map { view, width in
            view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (view, width) in zip(subviews, widths(bounds.width)) {
            view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                       proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}
