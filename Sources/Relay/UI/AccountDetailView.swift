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
                VStack(alignment: .leading, spacing: 10) {
                    accountIdentity
                    if account.kind == .workbuddy2api {
                        creditDetails
                        trendSection
                    } else {
                        metrics
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
                    if account.kind == .workbuddy2api, account.parentAccountID != nil {
                        subAccountManagement
                    }
                }
                .padding(.horizontal, 14)
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
        return account.lastUpdated == nil ? "未刷新" : "已更新"
    }

    private var footerDetailText: String {
        if let dataErrorMessage { return "读取失败，保留上次数据：" + dataErrorMessage }
        if !account.isEnabled { return "账户已停用；" + lastUpdatedText }
        let detail = AccountHealthPresentation(account: account, health: health).detail
        return detail.isEmpty ? lastUpdatedText : detail + "；" + lastUpdatedText
    }

    private var accountIdentity: some View {
        HStack(spacing: 9) {
            RelayProviderIcon(kind: account.kind, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.name).font(.system(size: 15, weight: .semibold)).tracking(-0.3).lineLimit(1)
                    .help(account.name)
                Text(account.kind.displayName + " · " + SiteAccountGroup.displayAddress(for: account))
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 2)
            Label(compactFooterText, systemImage: statusSymbol)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 90)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(statusColor).padding(.horizontal, 8).padding(.vertical, 4)
                .background(statusColor.opacity(0.07), in: Capsule())
                .help(footerDetailText).accessibilityLabel(footerDetailText)
        }
    }

    private var creditDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("可用积分").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Text(account.availablePoints.map { RelayNumberFormatter.decimal($0) } ?? "—")
                        .font(.system(size: 32, weight: .semibold)).tracking(-0.8).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                Spacer(minLength: 8)
                Image(systemName: "bolt.fill").font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary).frame(width: 54, height: 54)
                    .background(Color.primary.opacity(0.04), in: Circle()).accessibilityHidden(true)
            }
            Text("网关积分独立统计，不与货币余额合计。")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(cockpitSurface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var subAccountManagement: some View {
        DisclosureGroup("子账户管理") {
            VStack(alignment: .leading, spacing: 10) {
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
            }.padding(.top, 8)
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
    }

    private var metrics: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("今日消费").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .help("按供应商当日口径统计")
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        if account.todaySpend != nil {
                            Text(account.currency.symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
                        }
                        Text(account.todaySpend.map(RelayNumberFormatter.decimal) ?? "—")
                            .font(.system(size: 32, weight: .semibold)).tracking(-0.8)
                    }
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    if let change = dayOverDayChange {
                        HStack(spacing: 4) {
                            HStack(spacing: 3) {
                                Image(systemName: change.delta > 0 ? "arrow.up.right" : change.delta < 0 ? "arrow.down.right" : "arrow.right")
                                Text(RelayNumberFormatter.percent(abs(change.delta / change.previous))).monospacedDigit()
                            }
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(comparisonColor(change.delta))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(comparisonColor(change.delta).opacity(0.08), in: Capsule())
                            Text("较昨日").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .help("较昨日消费变化")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("较昨日消费\(change.delta > 0 ? "增加" : change.delta < 0 ? "减少" : "持平") \(RelayNumberFormatter.percent(abs(change.delta / change.previous)))")
                    } else {
                        Text("供应商当日口径").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                budgetGauge
            }
            .frame(height: 74)
            Divider().opacity(0.45)
            HStack(spacing: 8) {
                cockpitMetric("可用余额", value: account.balance)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5, height: 27)
                cockpitMetric("本月消费", value: account.monthSpend)
            }
        }
        .padding(12)
        .background(cockpitSurface, in: RoundedRectangle(cornerRadius: 14))
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var cockpitSurface: Color {
        Color.accentColor.opacity(contrast == .increased ? 0.12 : colorScheme == .dark ? 0.09 : 0.055)
    }

    private func cockpitMetric(_ title: String, value: Decimal?) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value.map { RelayNumberFormatter.money($0, currency: account.currency) } ?? "—")
                .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var budgetGauge: some View {
        let state = budgetProgress
        let ratio = state.ratio
        let gaugeColor: Color = (ratio ?? 0) >= 1 ? .orange : .accentColor
        return VStack(spacing: 7) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 4)
                if let ratio {
                    Circle().trim(from: 0, to: CGFloat(min(1, max(0, NSDecimalNumber(decimal: ratio).doubleValue))))
                        .stroke(gaugeColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 3) {
                    Text(ratio.map { ($0 * 100).formatted(.number.precision(.fractionLength(0...1))) + "%" } ?? "—")
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(ratio == nil ? monthlyBudget == nil ? "未设预算" : "数据不足" : "预算已用")
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                }.padding(5)
            }
            .frame(width: 54, height: 54)
            Text(monthlyBudget.map { "月预算 " + RelayNumberFormatter.modelMetric($0.amount, currency: $0.currency) } ?? "可在编辑中设置")
                .font(.system(size: 8.5)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(width: 88)
        .help(budgetGaugeDetail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("月预算：" + budgetGaugeDetail)
    }

    private var budgetProgress: BudgetProgress {
        guard let id = historyAccountID else { return .disabled }
        return BudgetService.progress(budget: monthlyBudget, snapshot: budgetSnapshot, accountID: id,
            now: presentationDate, calendar: historyCalendar)
    }

    private var budgetGaugeDetail: String {
        switch budgetProgress {
        case .disabled: return "未设置月预算，可在编辑账户中设置。"
        case .unavailable(let reason): return reason
        case let .known(spend, budget, ratio):
            let difference = budget.amount - spend.amount
            return "已用 " + RelayNumberFormatter.percent(ratio) + "；预算 "
                + RelayNumberFormatter.money(budget.amount, currency: budget.currency) + "；"
                + (difference >= 0 ? "剩余 " : "超出 ")
                + RelayNumberFormatter.money(abs(difference), currency: budget.currency)
                + (budgetSnapshot?.freshness == .fresh ? "" : "；上次成功的缓存数据")
        }
    }

    private func comparisonColor(_ delta: Decimal) -> Color {
        delta > 0 ? .red : delta < 0 ? .green : .secondary
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

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("消费趋势")
                    .font(.system(size: 11.5, weight: .semibold))
                    .help(trendExplanation).accessibilityHint(trendExplanation)
                Spacer()
                Text("近 7 日 · " + (account.kind == .workbuddy2api ? "积分" : account.currency.rawValue))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            historyCoverageControls
            if displayedHistoryPoints.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 18)).foregroundStyle(.tertiary)
                    Text("暂未积累趋势数据").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(account.kind == .workbuddy2api ? "后续刷新将记录积分增量，缺日不补零。" : "成功采集后形成趋势，缺失日期为未知。")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).frame(height: 94)
            } else {
                AdaptiveLineChart(dataPoints: displayedHistoryPoints,
                    unit: account.kind == .workbuddy2api ? "积分" : account.currency.symbol,
                    isCompact: true) { point in
                        selectedTrendDay = point?.day
                    }
                    .frame(height: 94)
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
                    .font(.system(size: 9)).foregroundStyle(.secondary)
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
        let requestTitle = account.kind == .deepseek ? "本月请求" : account.kind == .workbuddy2api ? "进程累计请求" : "账户累计请求"
        let tokenTitle = account.kind == .workbuddy2api ? "进程 Token" : selectedModelDateLabel + " Token"
        return HStack(spacing: 6) {
            Text(requestTitle).foregroundStyle(.secondary)
            Text(requests.map(RelayNumberFormatter.tokens) ?? "—").monospacedDigit()
                .help((account.kind == .workbuddy2api ? "网关进程累计请求：" : account.kind == .pipio ? "账户累计请求：" : "本月请求：")
                    + (requests.map { $0.formatted() } ?? "未知"))
            Spacer(minLength: 2)
            Text(tokenTitle).foregroundStyle(.secondary)
            Text(tokens.flatMap { $0 >= 0 ? RelayNumberFormatter.tokens($0) : nil } ?? "—").monospacedDigit()
                .help((account.kind == .workbuddy2api ? "网关全部账号本进程总 Token：" : "该日已获取模型 Token 合计：")
                    + (tokens.map { $0.formatted() } ?? "未知"))
        }
        .font(.system(size: 9.5)).lineLimit(1).minimumScaleFactor(0.85)
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
