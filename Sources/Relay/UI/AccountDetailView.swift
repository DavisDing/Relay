import SwiftUI

/// 账号消耗详情与趋势自适应抽屉/页面
public struct AccountDetailView: View {
    public let account: AccountModel
    public let spendPoints: [DailySpendPoint]
    public let modelUsages: [ModelUsageItem]
    public var onClose: () -> Void
    
    public init(account: AccountModel,
                spendPoints: [DailySpendPoint] = [],
                modelUsages: [ModelUsageItem] = [],
                onClose: @escaping () -> Void = {}) {
        self.account = account
        self.spendPoints = spendPoints
        self.modelUsages = modelUsages
        self.onClose = onClose
    }
    
    public var body: some View {
        VStack(spacing: 16) {
            // 顶部导航区（纯净无技术 ID）
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.name)
                        .font(.system(size: 16, weight: .bold))
                    Text(account.baseURL)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(account.kind.rawValue)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
                
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            
            // 核心 3 指标卡片
            HStack(spacing: 10) {
                MetricCard(
                    title: "账户可用余额",
                    value: account.balance.map { "\(account.currency.symbol)\($0)" } ?? "--",
                    subTitle: "实时同步正常",
                    accentColor: .primary
                )
                if let todaySpend = account.todaySpend {
                    MetricCard(
                        title: "今日消耗",
                        value: "\(account.currency.symbol)\(todaySpend)",
                        subTitle: "全天计费",
                        accentColor: .orange
                    )
                }
                MetricCard(
                    title: "本月累计账单",
                    value: account.monthSpend != nil ? "\(account.currency.symbol)\(account.monthSpend!)" : "--",
                    subTitle: "按账单周期",
                    accentColor: .primary
                )
            }
            .padding(.horizontal, 20)
            
            // 近 7 日消耗趋势折线图 (完全自适应容器)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("近 7 日消耗趋势走势图")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("币种: \(account.currency.rawValue)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                AdaptiveLineChart(dataPoints: spendPoints, unit: account.currency.symbol)
                    .frame(minHeight: 140, idealHeight: 160)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                    )
            }
            .padding(.horizontal, 20)
            
            // 模型调用细分明细 (Top)
            VStack(alignment: .leading, spacing: 6) {
                Text("模型消耗分析 (Top)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                
                VStack(spacing: 6) {
                    ForEach(modelUsages) { item in
                        HStack {
                            Text(item.modelName)
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(item.tokens)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(item.currency.symbol)\(item.cost)")
                                .font(.system(size: 12, weight: .semibold))
                            Text(String(format: "%.0f%%", item.percentage * 100))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .frame(width: 32, alignment: .trailing)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
                        .cornerRadius(6)
                    }
                }
            }
            .padding(.horizontal, 20)
            
            Spacer(minLength: 4)
            
            // 底部关闭返回按钮
            HStack {
                Spacer()
                Button("关闭返回", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 420, minHeight: 480)
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
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subTitle)
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }
}
