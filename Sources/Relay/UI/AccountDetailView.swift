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
                cumulativeModelUsages: data.cumulativeModelUsages,
                modelStatsSince: data.modelStatsSince,
                deepSeekUsageReport: data.deepSeekUsageReport,
                dataErrorMessage: state.errorMessage,
                health: historyID.map { store.health(for: $0) },
                historyRecords: historyID.map { store.dailyUsage(accountID: $0, limit: nil) },
                monthlyBudget: configuration?.monthlyBudget,
                budgetSnapshot: historyID.flatMap { store.accountSnapshot(id: $0) },
                presentationDate: store.presentationDate,
                onClose: onClose,
                onSubAccountAction: onSubAccountAction
            )
        } else if let message = state.errorMessage {
            VStack(spacing: 12) {
                Text(message).foregroundStyle(.secondary)
                Button("返回首页", action: onClose)
            }
            .frame(width: RelayVisualStyle.detailPanelWidth, height: RelayVisualStyle.detailPanelHeight)
            .relayPanelSurface(cornerRadius: RelayVisualStyle.panelCornerRadius)
        } else {
            // Only a successful read confirming removal may close the page.
            Color.clear.onAppear(perform: onClose)
        }
    }
}

/// Account details with persisted daily and model aggregates.
/// Relay backfills only documented provider history and never
/// fabricates a spend value for days that cannot be queried.
public struct AccountDetailView: View {
    public let account: AccountModel
    public let spendPoints: [DailySpendPoint]
    public let modelUsages: [ModelUsageItem]
    public let cumulativeModelUsages: [ModelUsageItem]?
    public let modelStatsSince: Date?
    public let deepSeekUsageReport: DeepSeekUsageReport?
    public let dataErrorMessage: String?
    public let health: AccountHealth?
    public let historyRecords: [DailyUsageRecord]?
    public let monthlyBudget: MoneyValue?
    public let budgetSnapshot: ProviderSnapshot?
    public let presentationDate: Date
    public var onClose: () -> Void
    public var onSubAccountAction: (ProviderSubAccountAction, UUID, String) async throws -> Void
    @State private var confirmingAction: ProviderSubAccountAction?
    @State private var actionError: String?
    @State private var isActing = false
    @State private var selectedTrendDay: Date?

    public init(
        account: AccountModel,
        spendPoints: [DailySpendPoint] = [],
        modelUsages: [ModelUsageItem] = [],
        cumulativeModelUsages: [ModelUsageItem]? = nil,
        modelStatsSince: Date? = nil,
        deepSeekUsageReport: DeepSeekUsageReport? = nil,
        dataErrorMessage: String? = nil,
        health: AccountHealth? = nil,
        historyRecords: [DailyUsageRecord]? = nil,
        monthlyBudget: MoneyValue? = nil,
        budgetSnapshot: ProviderSnapshot? = nil,
        presentationDate: Date = Date(),
        onClose: @escaping () -> Void = {},
        onSubAccountAction: @escaping (ProviderSubAccountAction, UUID, String) async throws -> Void = { _, _, _ in }
    ) {
        self.account = account
        self.spendPoints = spendPoints
        self.modelUsages = modelUsages
        self.cumulativeModelUsages = cumulativeModelUsages
        self.modelStatsSince = modelStatsSince
        self.deepSeekUsageReport = deepSeekUsageReport
        self.dataErrorMessage = dataErrorMessage
        self.health = health
        self.historyRecords = historyRecords
        self.monthlyBudget = monthlyBudget
        self.budgetSnapshot = budgetSnapshot
        self.presentationDate = presentationDate
        self.onClose = onClose
        self.onSubAccountAction = onSubAccountAction
    }

    public var body: some View {
        VStack(spacing: 0) {
            RelayPageHeader(title: "账户详情", onBack: onClose,
                accessorySystemImage: accountWebsiteURL == nil ? nil : "safari",
                accessoryLabel: "打开账户官网", onAccessory: openAccountWebsite)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    accountIdentity
                    if account.kind == .workbuddy2api {
                        creditDetails
                        trendSection
                    } else {
                        metrics
                        Divider().opacity(0.5)
                        trendSection
                    }

                    usageMetrics
                    if account.kind == .deepseek, deepSeekUsageReport?.coverage == .unsupported {
                        DeepSeekUsageSection(report: deepSeekUsageReport)
                    }
                    ModelAnalysisPanel(items: selectedModelItems, dateLabel: selectedModelDateLabel,
                        scope: account.kind == .workbuddy2api ? .processCredits : .dailySpend,
                        processSince: modelStatsSince,
                        unavailableMessage: account.kind == .workbuddy2api
                            ? "暂未获取网关累计模型统计，请刷新账户。"
                            : historyCalendar.isDate(selectedModelDate, inSameDayAs: presentationDate)
                                ? "当天暂无可用模型明细，请刷新账户。"
                                : "该日期暂无可用模型明细，可在编辑账户中回填历史。")
                    if account.kind != .workbuddy2api, monthlyBudget != nil, let id = UUID(uuidString: account.id) {
                        DisclosureGroup("本月预算与提醒") {
                            BudgetAccountPanel(budget: monthlyBudget, snapshot: budgetSnapshot,
                                               accountID: id, provider: account.kind)
                        }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)

        }
        .frame(width: RelayVisualStyle.detailPanelWidth, height: RelayVisualStyle.detailPanelHeight)
        .relayPanelSurface(cornerRadius: RelayVisualStyle.panelCornerRadius)
        .onChange(of: displayedHistoryPoints.map(\.id)) { _, _ in
            if let selectedTrendDay, !displayedHistoryPoints.contains(where: { $0.day == selectedTrendDay }) {
                self.selectedTrendDay = nil
            }
        }
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

    private var compactFooterText: String {
        if dataErrorMessage != nil { return "读取失败" }
        if !account.isEnabled { return "已停用" }
        if let message = AccountHealthPresentation(account: account, health: health).subAccountStatusMessage {
            return message
        }
        if let health {
            switch health.phase {
            case .queued: return "排队中"
            case .refreshing: return "刷新中"
            case .backingOff: return health.issue == .rateLimit ? "限流中" : "待重试"
            case .idle: break
            }
            if let issue = health.issue {
                switch issue {
                case .credentials: return "凭据失效"
                case .permission: return "权限不足"
                case .rateLimit: return "限流中"
                case .network: return "网络异常"
                case .provider: return "服务异常"
                case .incompatibleResponse: return "数据异常"
                case .storage: return "存储异常"
                }
            }
            if health.freshness == .stale { return "缓存数据" }
            if health.freshness == .partial { return "部分数据" }
        }
        guard let updated = account.lastUpdated else { return "未刷新" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Calendar.current.isDateInToday(updated) ? "HH:mm" : "MM/dd HH:mm"
        return "更新 " + formatter.string(from: updated)
    }

    private var footerDetailText: String {
        if let dataErrorMessage { return "读取失败，保留上次数据：" + dataErrorMessage }
        if !account.isEnabled { return "账户已停用；" + lastUpdatedText }
        let detail = AccountHealthPresentation(account: account, health: health).detail
        return detail.isEmpty ? lastUpdatedText : detail + "；" + lastUpdatedText
    }

    private var accountIdentity: some View {
        HStack(spacing: 10) {
            RelayProviderIcon(kind: account.kind, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.name).font(.system(size: 18, weight: .semibold)).tracking(-0.5).lineLimit(1)
                Text(account.kind.displayName + " · " + SiteAccountGroup.displayAddress(for: account))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Label(compactFooterText, systemImage: statusSymbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(statusColor).padding(.horizontal, 10).padding(.vertical, 6)
                .background(statusColor.opacity(0.07), in: Capsule())
                .help(footerDetailText).accessibilityLabel(footerDetailText)
        }
    }

    private var creditDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("可用积分").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(account.availablePoints.map { RelayNumberFormatter.decimal($0) } ?? "—")
                .font(.system(size: 28, weight: .semibold)).tracking(-1).monospacedDigit()
            Text("网关积分独立统计，不与货币余额合计。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if account.parentAccountID != nil {
                Divider().opacity(0.5)
                Text("内部 UID：\(account.externalID ?? "—")")
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Text("系统停用：\(account.disabled ? "是" : "否") · 手动停用：\(account.manualDisabled ? "是" : "否") · 冷却：\(account.cooling ? "是" : "否")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let actionError { Text(actionError).font(.system(size: 12)).foregroundStyle(.red) }
                HStack {
                    Button("手动停用") { confirmingAction = .disable(reason: "由 Relay 手动停用") }
                        .disabled(isActing || account.manualDisabled)
                    Button("解除手动停用") { confirmingAction = .enable }
                        .disabled(isActing || !account.manualDisabled)
                }.buttonStyle(RelaySecondaryCapsuleButtonStyle())
                Text("管理功能需在网关启用 admin.enabled；操作后会刷新快照。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("今日消费").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                HStack(alignment: .center, spacing: 8) {
                    Text(account.todaySpend.map { RelayNumberFormatter.money($0, currency: account.currency) } ?? "—")
                        .font(.system(size: 28, weight: .semibold)).tracking(-0.8)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    if let change = dayOverDayChange {
                        VStack(alignment: .trailing, spacing: 3) {
                            Image(systemName: change.delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 10, weight: .semibold))
                            Text(RelayNumberFormatter.percent(abs(change.delta / change.previous)))
                                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        }
                        .foregroundStyle(change.delta > 0 ? Color.red : change.delta < 0 ? Color.green : Color.secondary)
                        .fixedSize()
                        .help("较昨日消费变化")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("较昨日消费\(change.delta > 0 ? "增加" : change.delta < 0 ? "减少" : "持平") \(RelayNumberFormatter.percent(abs(change.delta / change.previous)))")
                    }
                }
                Text(dayOverDayChange == nil ? "供应商当日口径" : "较昨日 · 供应商当日口径")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))

            HStack(alignment: .top, spacing: 12) {
                MetricCard(title: "可用余额",
                    value: account.balance.map { RelayNumberFormatter.money($0, currency: account.currency) } ?? "—",
                    subTitle: account.currency.rawValue + " · 当前快照")
                Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 0.5, height: 42)
                MetricCard(title: "本月消费",
                    value: account.monthSpend.map { RelayNumberFormatter.money($0, currency: account.currency) } ?? "—",
                    subTitle: monthlyBudget.map { "预算 " + RelayNumberFormatter.money($0.amount, currency: $0.currency) } ?? "供应商账单周期",
                    budgetUsage: budgetUsage, budgetStatusText: budgetStatusText)
            }
        }
        .padding(.top, 4)
    }

    private var dayOverDayChange: (previous: Decimal, delta: Decimal)? {
        guard let today = account.todaySpend, !today.isNaN,
              let accountID = historyAccountID,
              let yesterdayDate = historyCalendar.date(byAdding: .day, value: -1,
                  to: historyCalendar.startOfDay(for: presentationDate)),
              let yesterday = historyRecords?.first(where: {
                  $0.accountID == accountID && historyCalendar.isDate($0.day, inSameDayAs: yesterdayDate)
              })?.spend,
              yesterday.currency == account.currency, !today.isNaN, !yesterday.amount.isNaN,
              yesterday.amount > 0 else { return nil }
        return (yesterday.amount, today - yesterday.amount)
    }

    private var budgetUsage: Decimal? {
        guard let budget = monthlyBudget, let spend = account.monthSpend,
              budget.currency == account.currency,
              !budget.amount.isNaN, budget.amount > 0,
              !spend.isNaN, spend >= 0 else { return nil }
        return spend / budget.amount
    }

    private var budgetStatusText: String? {
        guard let budget = monthlyBudget, let spend = account.monthSpend,
              budget.currency == account.currency, budget.amount > 0,
              !budget.amount.isNaN, !spend.isNaN else { return nil }
        let difference = budget.amount - spend
        if difference >= 0 {
            return "已用 \(RelayNumberFormatter.percent(budgetUsage ?? .zero)) · 剩余 \(RelayNumberFormatter.money(difference, currency: budget.currency))"
        }
        return "已用 \(RelayNumberFormatter.percent(budgetUsage ?? .zero)) · 超出 \(RelayNumberFormatter.money(-difference, currency: budget.currency))"
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("消费趋势")
                    .font(.system(size: 12, weight: .semibold))
                    .help(trendExplanation).accessibilityHint(trendExplanation)
                Spacer()
                Text("近 7 日 · " + (account.kind == .workbuddy2api ? "积分" : account.currency.rawValue))
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
                .frame(height: 130)
                .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            } else {
                AdaptiveLineChart(dataPoints: displayedHistoryPoints,
                    unit: account.kind == .workbuddy2api ? "积分" : account.currency.symbol) { point in
                        selectedTrendDay = point?.day
                    }
                    .frame(height: 116)
                    .padding(.top, 4)
            }
        }
    }

    private var trendExplanation: String {
        account.kind == .pipio ? "历史按已完成日期查询，今天由正常刷新更新。"
            : account.kind == .workbuddy2api ? "根据 /v1/stats 的进程累计积分计算刷新增量；无法恢复未采集日期。"
            : "平台历史使用手动填写的 userToken，按北京时间统计；缺失日期为未知。"
    }

    private var historyCalendar: Calendar {
        account.kind == .deepseek ? DeepSeekUsageService.historyCalendar : .current
    }

    private var historyAccountID: UUID? { account.parentAccountID ?? UUID(uuidString: account.id) }

    private var displayedHistoryPoints: [DailySpendPoint] {
        guard let historyRecords, let id = historyAccountID else { return Array(spendPoints.suffix(7)) }
        return DailyModelUsageService.trendPoints(accountID: id, provider: account.kind, records: historyRecords,
            currency: account.currency, now: presentationDate, calendar: historyCalendar)
    }

    @ViewBuilder
    private var historyCoverageControls: some View {
        if let historyRecords, let id = historyAccountID {
            let coverage = HistoryCoverage.calculate(records: historyRecords, accountID: id,
                days: 7, now: presentationDate, calendar: historyCalendar, currency: account.currency)
            if !coverage.isComplete {
                Text("有效金额 \(coverage.knownDays)/7 天 · 缺失日期为未知")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var selectedModelDate: Date { selectedTrendDay ?? historyCalendar.startOfDay(for: presentationDate) }

    private var selectedModelDateLabel: String {
        if account.kind == .workbuddy2api { return "进程累计" }
        if historyCalendar.isDate(selectedModelDate, inSameDayAs: presentationDate) { return "今日" }
        let formatter = DateFormatter()
        formatter.calendar = historyCalendar; formatter.timeZone = historyCalendar.timeZone
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: selectedModelDate)
    }

    private var selectedModelItems: [ModelUsageItem]? {
        if account.kind == .workbuddy2api { return cumulativeModelUsages }
        guard let id = historyAccountID else { return nil }
        let models = DailyModelUsageService.models(accountID: id, provider: account.kind,
            day: selectedModelDate, records: historyRecords ?? [], snapshot: budgetSnapshot,
            calendar: historyCalendar)
        return models.map { ModelUsageItem.items(from: $0, currency: account.currency) }
    }

    private var usageMetrics: some View {
        let snapshot = budgetSnapshot
        let requestCount = snapshot?.requestCount.flatMap { $0 >= 0 ? $0 : nil }
        let sameMonth = snapshot.map { historyCalendar.isDate($0.fetchedAt, equalTo: presentationDate, toGranularity: .month) } ?? false
        let requests = account.kind == .deepseek && !sameMonth ? nil : requestCount
        let models = historyAccountID.flatMap { id in
            DailyModelUsageService.models(accountID: id, provider: account.kind, day: selectedModelDate,
                records: historyRecords ?? [], snapshot: snapshot, calendar: historyCalendar)
        }
        let tokens = account.kind == .workbuddy2api
            ? (snapshot?.modelUsages == nil ? nil : snapshot?.workBuddyStats?.total.totalTokens)
            : DailyModelUsageService.tokenCount(models)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(account.kind == .deepseek ? "本月请求" : account.kind == .workbuddy2api ? "进程累计请求" : "账户累计请求")
                Spacer()
                Text(requests.map { $0.formatted() } ?? "—").monospacedDigit()
            }
            HStack {
                Text(account.kind == .workbuddy2api ? "进程累计 Token" : selectedModelDateLabel + "已获取模型 Token")
                Spacer()
                Text(tokens.flatMap { $0 >= 0 ? RelayNumberFormatter.tokens($0) : nil } ?? "—").monospacedDigit()
                    .help(tokens.map { $0.formatted() } ?? "Token 用量未知")
            }
            if account.kind == .workbuddy2api {
                Text("网关全部账号统计，不分摊至子账户。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
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

    private var statusSymbol: String {
        if dataErrorMessage != nil { return "exclamationmark.triangle" }
        if !account.isEnabled { return "pause.circle" }
        if let health, health.phase.isActive { return "arrow.triangle.2.circlepath" }
        if health?.issue != nil || health?.freshness == .stale { return "exclamationmark.circle" }
        switch account.status {
        case .ok: return account.lastUpdated == nil ? "clock" : "checkmark.circle"
        default: return "exclamationmark.circle"
        }
    }

    private var statusColor: Color {
        if dataErrorMessage != nil || health?.issue != nil { return .orange }
        if !account.isEnabled || account.lastUpdated == nil { return .secondary }
        if health?.freshness == .stale { return .orange }

        switch account.status {
        case .ok: return .green
        case .warning, .retrying: return .orange
        case .error: return .red
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let subTitle: String
    var budgetUsage: Decimal? = nil
    var budgetStatusText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold)).tracking(-0.3)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            if let budgetUsage {
                ProgressView(value: min(1, max(0, NSDecimalNumber(decimal: budgetUsage).doubleValue)))
                    .controlSize(.small)
                    .tint(budgetUsage >= 1 ? .orange : .accentColor)
                    .accessibilityLabel("月预算使用进度")
                if let budget = budgetStatusText {
                    Text(budget).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                }
            } else {
                Text(subTitle).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
    }

}
