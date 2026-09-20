import SwiftUI

/// A self-contained usage section for future DeepSeek usage data.
/// It deliberately distinguishes unsupported data from an empty/zero result.
public struct DeepSeekUsageSection: View {
    public let report: DeepSeekUsageReport?

    public init(report: DeepSeekUsageReport?) {
        self.report = report
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DeepSeek 用量")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            switch report?.coverage {
            case .complete, .partial:
                usageRows
            case .unsupported, .none:
                Text("DeepSeek 官方 API 暂未提供历史或分模型账户用量。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var usageRows: some View {
        if let report, let models = report.models, !models.isEmpty {
            ForEach(models) { model in
                HStack {
                    Text(model.modelName)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    metricText(model.tokenCount.map(String.init), label: "tokens")
                    metricText(model.requestCount.map(String.init), label: "requests")
                    if let spend = model.spend {
                        Text(spend.currency.symbol + spend.amount.description)
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .padding(.vertical, 4)
            }
        } else if let report, let daily = report.daily, !daily.isEmpty {
            ForEach(daily) { day in
                HStack {
                    Text(day.day.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11))
                    Spacer()
                    metricText(day.tokenCount.map(String.init), label: "tokens")
                    metricText(day.requestCount.map(String.init), label: "requests")
                    if let spend = day.spend {
                        Text(spend.currency.symbol + spend.amount.description)
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .padding(.vertical, 4)
            }
        } else {
            Text("暂无可展示的用量数据。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func metricText(_ value: String?, label: String) -> some View {
        if let value {
            Text("\(value) \(label)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}
