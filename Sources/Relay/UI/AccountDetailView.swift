import AppKit
import SwiftUI

/// Observe the shared store inside the hosted window. Keep the child view's
/// identity stable so refreshes do not recreate the window or reset local UI state.
@MainActor
struct AccountDetailContainerView: View {
    @ObservedObject var store: RelayStore
    let accountID: String
    var onClose: () -> Void
    var onSubAccountAction: (ProviderSubAccountAction, UUID, String) async throws -> Void

    var body: some View {
        let state = store.accountDetailState(for: accountID)
        if let data = state.data {
            let historyID = data.account.parentAccountID ?? UUID(uuidString: data.account.id)
            let configuration = historyID.flatMap { store.accountConfiguration(id: $0) }
            AccountDetailView(
                account: data.account,
                spendPoints: data.spendPoints,
                modelUsages: data.modelUsages,
                deepSeekUsageReport: data.deepSeekUsageReport,
                dataErrorMessage: state.errorMessage,
                health: historyID.map { store.health(for: $0) },
                historyRecords: historyID.map { store.dailyUsage(accountID: $0, limit: nil) },
                historyBackfillState: historyID.flatMap { store.historyBackfillStates[$0] },
                monthlyBudget: configuration?.monthlyBudget,
                budgetSnapshot: historyID.flatMap { id in store.snapshots.first { $0.accountID == id } },
                onHistoryBackfill: { days in
                    guard let historyID else { return }
                    store.startHistoryBackfill(accountID: historyID, days: days)
                },
                onCancelHistoryBackfill: {
                    guard let historyID else { return }
                    store.cancelHistoryBackfill(accountID: historyID)
                },
                onClose: onClose,
                onSubAccountAction: onSubAccountAction
            )
        } else if let message = state.errorMessage {
            VStack(spacing: 12) {
                Text(message).foregroundStyle(.secondary)
                Button("返回首页", action: onClose)
            }
            .frame(width: RelayVisualStyle.panelWidth, height: 520)
            .relayPanelSurface(cornerRadius: RelayVisualStyle.panelCornerRadius)
        } else {
            // Only a successful read confirming removal may close the page.
            Color.clear.onAppear(perform: onClose)
        }
    }
}

/// Account details with persisted daily aggregates and the provider's current
/// model aggregate. Relay backfills only documented provider history and never
/// fabricates a spend value for days that cannot be queried.
public struct AccountDetailView: View {
    public let account: AccountModel
    public let spendPoints: [DailySpendPoint]
    public let modelUsages: [ModelUsageItem]
    public let deepSeekUsageReport: DeepSeekUsageReport?
    public let dataErrorMessage: String?
    public let health: AccountHealth?
    public let historyRecords: [DailyUsageRecord]?
    public let historyBackfillState: HistoryBackfillState?
    public let monthlyBudget: MoneyValue?
    public let budgetSnapshot: ProviderSnapshot?
    public var onHistoryBackfill: (Int) -> Void
    public var onCancelHistoryBackfill: () -> Void
    @State private var selectedHistoryDays = 7
    public var onClose: () -> Void
    public var onSubAccountAction: (ProviderSubAccountAction, UUID, String) async throws -> Void
    @State private var confirmingAction: ProviderSubAccountAction?
    @State private var actionError: String?
    @State private var isActing = false

    public init(
        account: AccountModel,
        spendPoints: [DailySpendPoint] = [],
        modelUsages: [ModelUsageItem] = [],
        deepSeekUsageReport: DeepSeekUsageReport? = nil,
        dataErrorMessage: String? = nil,
        health: AccountHealth? = nil,
        historyRecords: [DailyUsageRecord]? = nil,
        historyBackfillState: HistoryBackfillState? = nil,
        monthlyBudget: MoneyValue? = nil,
        budgetSnapshot: ProviderSnapshot? = nil,
        onHistoryBackfill: @escaping (Int) -> Void = { _ in },
        onCancelHistoryBackfill: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {},
        onSubAccountAction: @escaping (ProviderSubAccountAction, UUID, String) async throws -> Void = { _, _, _ in }
    ) {
        self.account = account
        self.spendPoints = spendPoints
        self.modelUsages = modelUsages
        self.deepSeekUsageReport = deepSeekUsageReport
        self.dataErrorMessage = dataErrorMessage
        self.health = health
        self.historyRecords = historyRecords
        self.historyBackfillState = historyBackfillState
        self.monthlyBudget = monthlyBudget
        self.budgetSnapshot = budgetSnapshot
        self.onHistoryBackfill = onHistoryBackfill
        self.onCancelHistoryBackfill = onCancelHistoryBackfill
        self.onClose = onClose
        self.onSubAccountAction = onSubAccountAction
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if account.kind == .workbuddy2api {
                        creditDetails
                        trendSection
                    } else {
                        metrics
                        if let id = UUID(uuidString: account.id) {
                            BudgetAccountPanel(budget: monthlyBudget, snapshot: budgetSnapshot,
                                               accountID: id, provider: account.kind)
                        }
                        trendSection
                    }

                    if account.kind == .deepseek {
                        DeepSeekUsageSection(
                            report: deepSeekUsageReport ?? UUID(uuidString: account.id).map { DeepSeekUsageReport.unsupported(accountID: $0) }
                        )
                    } else {
                        if modelUsages.isEmpty { modelUsageSection }
                        else { ModelAnalysisPanel(items: modelUsages) }
                    }
                    if account.kind == .deepseek { ModelAnalysisPanel(items: modelUsages) }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)

            Divider().opacity(0.35)
            HStack {
                Text(dataErrorMessage.map { "读取失败，保留上次数据：" + $0 } ?? healthFooterText)
                    .font(.system(size: 10))
                    .foregroundStyle(dataErrorMessage == nil ? Color.secondary : Color.red)
                    .help(dataErrorMessage ?? healthFooterText)
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
        .frame(width: RelayVisualStyle.panelWidth, height: 520)
        .relayPanelSurface(cornerRadius: RelayVisualStyle.panelCornerRadius)
        .alert(confirmingAction == .enable ? "确认启用内部账号？" : "确认手动停用内部账号？",
               isPresented: Binding(get: { confirmingAction != nil }, set: { if !$0 { confirmingAction = nil } })) {
            Button("取消", role: .cancel) { confirmingAction = nil }
            Button("确认") {
                guard let action = confirmingAction, let parent = account.parentAccountID,
                      let uid = account.externalID else { return }
                confirmingAction = nil
                isActing = true
                Task { @MainActor in
                    do { try await onSubAccountAction(action, parent, uid); onClose() }
                    catch { actionError = error.localizedDescription; isActing = false }
                }
            }
        } message: {
            Text("此操作会调用网关管理接口；网关必须启用 admin.enabled。启用仅解除手动停用，不会解除系统自动停用。")
        }
    }

    private var healthFooterText: String {
        guard let health, account.isEnabled else { return lastUpdatedText }
        return health.summary + " · " + lastUpdatedText
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
            Text(account.kind.displayName)
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

    private var creditDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                MetricCard(title: "可用积分",
                    value: account.availablePoints.map { RelayNumberFormatter.decimal($0) } ?? "--",
                    subTitle: "网关当前快照", accentColor: .primary)
                MetricCard(title: "统计来源", value: "/v1/stats",
                    subTitle: "刷新时读取并去重", accentColor: .secondary)
            }
            Text("内部 UID：\(account.externalID ?? "--")")
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Text("系统停用：\(account.disabled ? "是" : "否") · 手动停用：\(account.manualDisabled ? "是" : "否") · 冷却：\(account.cooling ? "是" : "否")")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("趋势按每次刷新读取的 /v1/stats 进程累计值计算增量并去重；容器重启前未刷新到 Relay 的区间无法恢复。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let actionError { Text(actionError).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Button("手动停用") { confirmingAction = .disable(reason: "由 Relay 手动停用") }
                    .disabled(isActing || account.manualDisabled)
                Button("解除手动停用") { confirmingAction = .enable }
                    .disabled(isActing || !account.manualDisabled)
            }.buttonStyle(.bordered)
            Text("管理功能需在 WordBuddy2Api 中启用 admin.enabled；操作后会刷新快照。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
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
                    Text("近 \(selectedHistoryDays) 日消耗趋势")
                        .font(.system(size: 13, weight: .semibold))
                    Text(account.kind == .pipio ? "历史按已完成日期查询，今天由正常刷新更新。" : account.kind == .workbuddy2api ? "根据 /v1/stats 的进程累计积分计算刷新增量；无法恢复未采集日期。" : "平台历史使用手动填写的 userToken，按北京时间统计；缺失日期为未知。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(account.kind == .workbuddy2api ? "积分" : account.currency.rawValue)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            historyCoverageControls
            if displayedHistoryPoints.isEmpty {
                ContentUnavailableView(
                    "暂未积累趋势数据",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text(account.kind == .pipio ? "Pipio 未返回可用的历史统计；请稍后刷新。" : account.kind == .workbuddy2api ? "首次刷新后会保存积分增量；请继续刷新以形成趋势。" : "后续成功同步会保存当天累计，并逐日形成趋势。")
                )
                .frame(height: 155)
                .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            } else {
                AdaptiveLineChart(dataPoints: displayedHistoryPoints, unit: account.kind == .workbuddy2api ? "积分" : account.currency.symbol)
                    .frame(height: 165)
                    .padding(8)
                    .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var historyCalendar: Calendar {
        account.kind == .deepseek ? DeepSeekUsageService.historyCalendar : .current
    }

    private var historyAccountID: UUID? { account.parentAccountID ?? UUID(uuidString: account.id) }

    private var displayedHistoryPoints: [DailySpendPoint] {
        guard let historyRecords, let id = historyAccountID else { return spendPoints }
        let calendar = historyCalendar
        let today = calendar.startOfDay(for: Date())
        guard let firstDay = calendar.date(byAdding: .day, value: -(selectedHistoryDays - 1), to: today),
              let afterToday = calendar.date(byAdding: .day, value: 1, to: today) else { return [] }
        let formatter = DateFormatter(); formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "MM/dd"
        return historyRecords.filter {
            $0.accountID == id && $0.day >= firstDay && $0.day < afterToday && $0.spend?.currency == account.currency
        }.sorted { $0.day < $1.day }.compactMap { record in
            guard let spend = record.spend else { return nil }
            return DailySpendPoint(id: record.id, dateString: formatter.string(from: record.day), amount: spend.amount)
        }
    }

    @ViewBuilder
    private var historyCoverageControls: some View {
        if let historyRecords, let id = historyAccountID {
            let coverage = HistoryCoverage.calculate(records: historyRecords, accountID: id,
                days: selectedHistoryDays, calendar: historyCalendar, currency: account.currency)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Picker("历史范围", selection: $selectedHistoryDays) {
                        Text("7 日").tag(7)
                        Text("30 日").tag(30)
                    }.pickerStyle(.segmented).frame(width: 135)
                    Spacer()
                    Text("有效金额 \(coverage.knownDays)/\(coverage.days) 天")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if !coverage.isComplete {
                    Text("尚有 \(coverage.missingDays.count) 天金额未知；图表只绘制已有记录，不能据此判断完整区间总额。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if account.kind != .workbuddy2api {
                    HStack(spacing: 8) {
                        Button("回填近 7 日") { onHistoryBackfill(7) }
                        Button("回填近 30 日") { onHistoryBackfill(30) }
                    }.buttonStyle(.bordered).controlSize(.small)
                        .disabled(!account.isEnabled || historyBackfillState?.isActive == true)
                    if !account.isEnabled {
                        Text("账户已停用，启用后可回填历史。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if let state = historyBackfillState {
                    if state.isActive {
                        HStack {
                            if account.kind == .deepseek { ProgressView().controlSize(.small) }
                            else { ProgressView(value: state.progress).frame(maxWidth: .infinity) }
                            Button("取消", action: onCancelHistoryBackfill).controlSize(.small)
                                .disabled(state.phase == .cancelling)
                        }
                    }
                    Text(state.message).font(.system(size: 10))
                        .foregroundStyle(state.phase == .failed ? Color.red : Color.secondary)
                }
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
                ModelUsageColumnLayout {
                    Text("模型")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("总 Token")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text("缓存读取")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text("消耗")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)

                ForEach(modelUsages) { item in
                    ModelUsageColumnLayout {
                        Text(item.modelName)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(item.modelName)
                        Text(item.tokenCount.map { RelayNumberFormatter.tokens($0) } ?? item.tokens)
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .help("\(item.tokens) Token")
                            .accessibilityLabel("总 Token：\(item.tokens)")
                        Text(item.cacheHitRate.map(RelayNumberFormatter.percent) ?? "--")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(item.cost.map {
                                account.kind == .workbuddy2api
                                    ? RelayNumberFormatter.decimal($0)
                                    : RelayNumberFormatter.money($0, currency: item.currency)
                            } ?? "--")
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.75)
                                .multilineTextAlignment(.trailing)
                            Text(item.percentage.map { String(format: "%.0f%%", $0 * 100) } ?? "--")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
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
        .relayGlassTile(cornerRadius: 10)
    }
}

/// Fixed 2:1:1:1 column proportions for both the header and every model row.
/// The first column gets two shares so model identifiers have more room while
/// staying on one line and not competing with the numeric columns.
private struct ModelUsageColumnLayout: Layout {
    private let spacing: CGFloat = 4

    private func columnWidths(for totalWidth: CGFloat) -> [CGFloat] {
        let share = max(0, totalWidth - spacing * 3) / 5
        return [share * 2, share, share, share]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width } + spacing * 3
        let widths = columnWidths(for: width)
        let height = zip(subviews, widths).map { subview, columnWidth in
            subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: proposal.height)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(for: bounds.width)
        var x = bounds.minX
        for (subview, columnWidth) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: columnWidth, height: bounds.height))
            x += columnWidth + spacing
        }
    }
}
