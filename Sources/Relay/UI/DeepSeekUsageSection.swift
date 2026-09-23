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
            case .complete:
                usageRows
            case .partial:
                Text("平台用量接口可能失效或 userToken 已过期；余额仍可查询。下方历史数据可能不是最新。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                usageRows
            case .unsupported:
                Text(unavailableMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .none:
                Text("暂无 DeepSeek 用量数据。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unavailableMessage: String {
        switch report?.unavailableReason {
        case .userTokenNotConfigured:
            return "未配置平台 userToken；当前仅查询余额。"
        case .officialAPIHasNoHistoricalOrModelUsageEndpoint:
            return "DeepSeek 平台用量接口不可用。"
        case .none:
            return "暂无 DeepSeek 用量数据。"
        }
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
                        Text(RelayNumberFormatter.money(spend.amount, currency: spend.currency))
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .padding(.vertical, 4)
            }
        } else if let report, let daily = report.daily, !daily.isEmpty {
            ForEach(daily) { day in
                HStack {
                    Text(formattedDay(day.day))
                        .font(.system(size: 11))
                    Spacer()
                    metricText(day.tokenCount.map(String.init), label: "tokens")
                    metricText(day.requestCount.map(String.init), label: "requests")
                    if let spend = day.spend {
                        Text(RelayNumberFormatter.money(spend.amount, currency: spend.currency))
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


    private func formattedDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = DeepSeekUsageService.historyCalendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
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
