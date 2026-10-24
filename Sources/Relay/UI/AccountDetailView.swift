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
                budgetSnapshot: historyID.flatMap { id in store.snapshots.first { $0.accountID == id } },
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
    @State private var selectedHistoryPointID: String?
    public var onClose: () -> Void
    public var onSubAccountAction: (ProviderSubAccountAction, UUID, String) async throws -> Void
    @State private var confirmingAction: ProviderSubAccountAction?
    @State private var actionError: String?
    @State private var isActing = false

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

                    if account.kind == .deepseek, deepSeekUsageReport?.coverage == .unsupported {
                        DeepSeekUsageSection(report: deepSeekUsageReport)
                    }
                    ModelAnalysisPanel(items: selectedModelItems, dateLabel: selectedModelDateLabel,
                        scope: account.kind == .workbuddy2api ? .processCredits : .dailySpend,
                        processSince: modelStatsSince,
                        unavailableMessage: account.kind == .workbuddy2api
                            ? "暂未获取网关累计模型统计，请刷新账户。"
                            : historyCalendar.isDateInToday(selectedModelDate)
                                ? "当天暂无可用模型明细，请刷新账户。"
                                : "该日期暂无可用模型明细，可在编辑账户中回填历史。")
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)

            VStack(spacing: 8) {
                Text(compactFooterText)
                    .font(.system(size: 12))
                    .foregroundStyle(dataErrorMessage == nil ? Color.secondary : Color.red)
                    .help(footerDetailText)
                    .accessibilityLabel(footerDetailText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if accountWebsiteURL != nil {
                        Button(action: openAccountWebsite) {
                            Label("官网", systemImage: "safari")
                        }
                        .buttonStyle(RelaySecondaryCapsuleButtonStyle())
                    }
                    Button("返回首页", action: onClose)
                        .buttonStyle(RelayPrimaryCapsuleButtonStyle())
                }
                .padding(8)
                .relayFloatingBarSurface(cornerRadius: 32)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
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

    private var compactFooterText: String {
        if dataErrorMessage != nil { return "读取失败" }
        if !account.isEnabled { return "已停用" }
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
        return health.map { $0.detail + "；" + lastUpdatedText } ?? lastUpdatedText
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(RelayCircularIconButtonStyle(diameter: 40))
            .help("返回首页")
            .accessibilityLabel("返回首页")
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
        }
        .frame(minHeight: 56)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
                    Text("近 7 日消耗趋势")
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
                AdaptiveLineChart(dataPoints: displayedHistoryPoints,
                    unit: account.kind == .workbuddy2api ? "积分" : account.currency.symbol,
                    onSelect: { selectedHistoryPointID = $0?.id })
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
        guard let historyRecords, let id = historyAccountID else { return Array(spendPoints.suffix(7)) }
        let calendar = historyCalendar
        let today = calendar.startOfDay(for: Date())
        guard let firstDay = calendar.date(byAdding: .day, value: -6, to: today),
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
                days: 7, calendar: historyCalendar, currency: account.currency)
            Text("有效金额 \(coverage.knownDays)/7 天")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if !coverage.isComplete {
                Text("尚有 \(coverage.missingDays.count) 天金额未知；图表只绘制已有记录。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var selectedModelDate: Date {
        if let selectedHistoryPointID,
           let record = historyRecords?.first(where: { $0.id == selectedHistoryPointID }) {
            return record.day
        }
        return historyCalendar.startOfDay(for: Date())
    }

    private var selectedModelDateLabel: String {
        if account.kind == .workbuddy2api { return "进程累计" }
        if historyCalendar.isDateInToday(selectedModelDate) { return "今日" }
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
        VStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(subTitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(16)
        .relayGlassTile()
    }
}
