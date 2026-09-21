import AppKit
import SwiftUI

/// Account details with persisted daily aggregates and the provider's current
/// model aggregate. Relay backfills only documented provider history and never
/// fabricates a spend value for days that cannot be queried.
public struct AccountDetailView: View {
    public let account: AccountModel
    public let spendPoints: [DailySpendPoint]
    public let modelUsages: [ModelUsageItem]
    public let deepSeekUsageReport: DeepSeekUsageReport?
    public var onClose: () -> Void

    public init(
        account: AccountModel,
        spendPoints: [DailySpendPoint] = [],
        modelUsages: [ModelUsageItem] = [],
        deepSeekUsageReport: DeepSeekUsageReport? = nil,
        onClose: @escaping () -> Void = {}
    ) {
        self.account = account
        self.spendPoints = spendPoints
        self.modelUsages = modelUsages
        self.deepSeekUsageReport = deepSeekUsageReport
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    metrics
                    trendSection

                    if account.kind == .deepseek {
                        DeepSeekUsageSection(
                            report: deepSeekUsageReport ?? UUID(uuidString: account.id).map { DeepSeekUsageReport.unsupported(accountID: $0) }
                        )
                    } else {
                        modelUsageSection
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)

            Divider().opacity(0.35)
            HStack {
                Text(lastUpdatedText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if accountWebsiteURL != nil {
                    Button(action: openAccountWebsite) {
                        Label("在 Safari 打开", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button("返回首页", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
        }
        .frame(width: 400, height: 520)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text("账户详情与走势")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(account.name)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Text(account.kind.rawValue)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("返回首页")
            .accessibilityLabel("返回首页")
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var metrics: some View {
        HStack(spacing: 9) {
            MetricCard(
                title: "账户可用余额",
                value: account.balance.map { RelayNumberFormatter.money($0, currency: account.currency) } ?? "--",
                subTitle: "当前缓存快照",
                accentColor: .primary
            )
            if let todaySpend = account.todaySpend {
                MetricCard(
                    title: "今日消耗",
                    value: RelayNumberFormatter.money(todaySpend, currency: account.currency),
                    subTitle: "仅显示完整数据",
                    accentColor: .orange
                )
            }
            MetricCard(
                title: "本月累计账单",
                value: account.monthSpend.map { RelayNumberFormatter.money($0, currency: account.currency) } ?? "--",
                subTitle: "按账单周期",
                accentColor: .primary
            )
        }
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("近 7 日消耗趋势")
                        .font(.system(size: 13, weight: .semibold))
                    Text(account.kind == .pipio ? "Pipio 会从公开统计接口回填可用的近 7 日；后续刷新持续更新当天累计。" : "官方接口未提供历史时，仅显示 Relay 已保存的每日累计。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(account.currency.rawValue)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if spendPoints.isEmpty {
                ContentUnavailableView(
                    "暂未积累趋势数据",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text(account.kind == .pipio ? "Pipio 未返回可用的历史统计；请稍后刷新。" : "后续成功同步会保存当天累计，并逐日形成趋势。")
                )
                .frame(height: 155)
                .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            } else {
                AdaptiveLineChart(dataPoints: spendPoints, unit: account.currency.symbol)
                    .frame(height: 165)
                    .padding(8)
                    .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var modelUsageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("模型消耗分析")
                .font(.system(size: 13, weight: .semibold))

            if modelUsages.isEmpty {
                Text("服务商未返回可用的分模型消耗数据。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 5)
            } else {
                HStack(spacing: 8) {
                    Text("模型")
                    Spacer()
                    Text("总 Token")
                        .frame(width: 76, alignment: .trailing)
                    Text("缓存读取")
                        .frame(width: 58, alignment: .trailing)
                    Text("消耗")
                        .frame(width: 68, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)

                ForEach(modelUsages) { item in
                    HStack(spacing: 8) {
                        Text(item.modelName)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(item.tokenCount.map { RelayNumberFormatter.tokens($0) } ?? item.tokens)
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(width: 76, alignment: .trailing)
                            .help("\(item.tokens) Token")
                            .accessibilityLabel("总 Token：\(item.tokens)")
                        Text(item.cacheHitRate.map(RelayNumberFormatter.percent) ?? "--")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(item.cost.map { RelayNumberFormatter.money($0, currency: item.currency) } ?? "--")
                                .font(.system(size: 11, weight: .semibold))
                            Text(item.percentage.map { String(format: "%.0f%%", $0 * 100) } ?? "--")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 68, alignment: .trailing)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    private var accountWebsiteURL: URL? {
        guard let url = URL(string: account.baseURL),
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    private func openAccountWebsite() {
        guard let url = accountWebsiteURL else { return }
        let safariURL = URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        guard FileManager.default.fileExists(atPath: safariURL.path) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: safariURL, configuration: configuration) { _, error in
            if error != nil { NSWorkspace.shared.open(url) }
        }
    }

    private var lastUpdatedText: String {
        guard let updated = account.lastUpdated else { return "尚未获得账户快照" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "MM/dd HH:mm"
        return "数据更新：\(formatter.string(from: updated))"
    }

    private var statusColor: Color {
        switch account.status {
        case .ok: return .green
        case .warning, .retrying: return .yellow
        case .error: return .red
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let subTitle: String
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(subTitle)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.35), lineWidth: 1))
    }
}
