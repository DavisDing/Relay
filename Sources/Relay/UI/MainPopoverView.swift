import AppKit
import SwiftUI

/// Site-first dashboard. Only actual local snapshots and provider capabilities
/// are shown; expansion is ephemeral and never changes account configuration.
public struct MainPopoverView: View {
    @ObservedObject private var store: RelayStore
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .followSystem
    @AppStorage("homeAmountsHidden") private var homeAmountsHidden = false
    @State private var expandedSites = Set<String>()
    @State private var highlightedAccountID: String?
    @State private var showSearch = false
    @State private var accountSearch = ""
    @State private var accountGroup: String?
    @State private var showConsumptionOverview = false
    @State private var showStorageRecovery = false
    @State private var accountPendingDeletion: AccountModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let onPresentAddAccount: () -> Void
    private let onPresentSettings: () -> Void
    private let onPresentAccountManagement: (() -> Void)?
    private let onPresentDetail: (AccountModel) -> Void
    private let onPresentEdit: (AccountModel) -> Void
    private let onPresentConsumptionOverview: (() -> Void)?

    public init(
        store: RelayStore,
        initialGlobalShortcutConfiguration: GlobalShortcutConfiguration = GlobalShortcutConfigurationStore.load(),
        onApplyGlobalShortcut: ((GlobalShortcutConfiguration) -> GlobalShortcutRegistrationOutcome)? = nil,
        onPresentAddAccount: @escaping () -> Void = {},
        onPresentSettings: @escaping () -> Void = {},
        onPresentDetail: @escaping (AccountModel) -> Void = { _ in },
        onPresentEdit: @escaping (AccountModel) -> Void = { _ in },
        onPresentConsumptionOverview: (() -> Void)? = nil,
        onPresentAccountManagement: (() -> Void)? = nil
    ) {
        self.store = store
        self.onPresentAddAccount = onPresentAddAccount
        self.onPresentSettings = onPresentSettings
        self.onPresentAccountManagement = onPresentAccountManagement
        self.onPresentDetail = onPresentDetail
        self.onPresentEdit = onPresentEdit
        self.onPresentConsumptionOverview = onPresentConsumptionOverview
    }

    private var visibleParents: [AccountModel] { store.accounts.filter { !$0.isHidden } }
    private var sites: [SiteAccountGroup] {
        SiteAccountGroup.groups(parents: store.accounts, dashboardAccounts: store.dashboardAccounts,
            configurations: store.accountConfigurations, query: accountSearch, group: accountGroup)
    }
    private func amount(_ text: String) -> String { homeAmountsHidden ? "••••" : text }
    private func money(_ value: Decimal?, currency: Currency) -> String {
        amount(value.map { RelayNumberFormatter.money($0, currency: currency) } ?? "—")
    }
    private func compactMoney(_ value: Decimal?, currency: Currency) -> String {
        amount(value.map { RelayNumberFormatter.compactMoney($0, currency: currency) } ?? "—")
    }
    private var todaySpend: Decimal? {
        store.todaySpendTotalCNY.isComplete ? store.todaySpendTotalCNY.value?.amount : nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if !store.storageAvailability.isAvailable { storageState }
            else if store.accounts.isEmpty { emptyState(hidden: false) }
            else if visibleParents.isEmpty { emptyState(hidden: true) }
            else { dashboard }
            footer
        }
        .frame(width: RelayVisualStyle.panelWidth, height: RelayVisualStyle.panelHeight)
        .relayPanelSurface()
        .preferredColorScheme(RelayVisualStyle.preferredColorScheme(for: appearanceMode))
        .onChange(of: accountSearch) { _, _ in expandMatchingSites() }
        .onChange(of: accountGroup) { _, _ in expandMatchingSites() }
        .sheet(isPresented: $showConsumptionOverview) {
            ConsumptionOverviewView(store: store, onClose: { showConsumptionOverview = false })
        }
        .sheet(isPresented: $showStorageRecovery) {
            StorageRecoveryView(store: store, onClose: { showStorageRecovery = false })
        }
        .alert("确认删除账户？", isPresented: Binding(
            get: { accountPendingDeletion != nil }, set: { if !$0 { accountPendingDeletion = nil } }
        )) {
            Button("取消", role: .cancel) { accountPendingDeletion = nil }
            Button("删除", role: .destructive) {
                guard let account = accountPendingDeletion, let id = UUID(uuidString: account.id) else { return }
                accountPendingDeletion = nil
                Task { await store.deleteAccount(id: id) }
            }
        } message: {
            Text("将删除本机账户数据和凭据。已启用同步时，删除标记也会同步到其他设备。")
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.fill").font(.system(size: 16))
            Text("Relay").font(.system(size: 16, weight: .semibold)).tracking(-0.4)
                .contextMenu {
                    Button("设置…", action: onPresentSettings)
                    Divider()
                    Button("退出 Relay", role: .destructive) { NSApplication.shared.terminate(nil) }
                }
            Spacer()
            Button { homeAmountsHidden.toggle() } label: {
                Image(systemName: homeAmountsHidden ? "eye.slash" : "eye")
            }
            .buttonStyle(RelayCircularIconButtonStyle(isSelected: homeAmountsHidden))
            .accessibilityLabel(homeAmountsHidden ? "显示首页金额与积分" : "隐藏首页金额与积分")
            .help(homeAmountsHidden ? "显示首页金额与积分" : "隐藏首页金额与积分")
            Button(action: onPresentSettings) { Image(systemName: "gearshape") }
                .buttonStyle(RelayCircularIconButtonStyle())
                .help("设置").accessibilityLabel("设置")
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 10)
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            if visibleParents.contains(where: { $0.kind != .workbuddy2api }) { spendingSummary }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = store.globalErrorMessage ?? store.syncErrorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    siteToolbar
                    if showSearch { RelaySearchField(text: $accountSearch) }
                    if let accountGroup {
                        HStack {
                            Text("分组：" + accountGroup).font(.system(size: 11)).foregroundStyle(.secondary)
                            Button("清除") { self.accountGroup = nil }.buttonStyle(RelayTextButtonStyle())
                        }
                    }
                    if sites.isEmpty {
                        Text("没有匹配的站点或账户").font(.callout).foregroundStyle(.secondary)
                        Button("清除筛选") { accountSearch = ""; accountGroup = nil }
                            .buttonStyle(RelayTextButtonStyle())
                    }
                    LazyVStack(spacing: 2) {
                        ForEach(sites) { site in siteGroup(site) }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 6)
            }
        }
    }

    private var spendingSummary: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if let onPresentConsumptionOverview { onPresentConsumptionOverview() }
                else { showConsumptionOverview = true }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("今日消费").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(alignment: .center, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(store.settings.baseCurrency.symbol)
                                .font(.system(size: 18)).foregroundStyle(.secondary)
                            Text(amount(todaySpend.map(RelayNumberFormatter.decimal) ?? "—"))
                                .font(.system(size: 32, weight: .semibold)).tracking(-1)
                        }
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 0)
                        if !homeAmountsHidden {
                            RelaySpendSparkline(values: store.dashboardSpendTrend)
                                .frame(width: 92, height: 38)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                    }
                    Text(todaySpend == nil ? "消费数据不完整，暂不合计"
                         : "\(visibleParents.filter { $0.isEnabled && $0.kind != .workbuddy2api }.count) 个计费账户 · \(store.settings.baseCurrency.rawValue)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
            }
            .buttonStyle(RelayCardButtonStyle())
            .accessibilityLabel("今日消费 " + money(todaySpend, currency: store.settings.baseCurrency))
            .accessibilityHint("打开当日与月度消费总览")
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, 16).opacity(0.5) }
    }

    private var siteToolbar: some View {
        HStack(spacing: 8) {
            Text("站点").font(.system(size: 12, weight: .semibold))
            Text("\(sites.count) 个站点 · \(sites.reduce(0) { $0 + $1.accounts.count }) 个账户")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer()
            Text("余额 / 积分").font(.system(size: 9)).foregroundStyle(.secondary)
            Button {
                withAnimation(reduceMotion ? nil : RelayVisualStyle.disclosureAnimation) {
                    showSearch.toggle()
                    if !showSearch { accountSearch = "" }
                }
            } label: { Image(systemName: "magnifyingglass") }
            .buttonStyle(RelayCircularIconButtonStyle(isSelected: showSearch))
            .accessibilityLabel(showSearch ? "收起搜索" : "搜索站点与账户")
            let groups = AccountOrganizationService.groups(in: store.accountConfigurations)
            if !groups.isEmpty {
                Menu {
                    Button("全部分组") { accountGroup = nil }
                    ForEach(groups, id: \.self) { group in
                        Button { accountGroup = group } label: {
                            if accountGroup == group { Label(group, systemImage: "checkmark") }
                            else { Text(group) }
                        }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                .accessibilityLabel(accountGroup.map { "筛选分组，当前：" + $0 } ?? "筛选分组")
            }
        }
        .padding(.horizontal, 8)
    }

    private func siteGroup(_ site: SiteAccountGroup) -> some View {
        let expanded = site.accounts.count > 1 && expandedSites.contains(site.id)
        return VStack(spacing: 0) {
            HStack(spacing: 3) {
                Button {
                    if site.accounts.count == 1, let account = site.matchingAccounts.first { onPresentDetail(account) }
                    else {
                        withAnimation(reduceMotion ? nil : RelayVisualStyle.disclosureAnimation) {
                            if !expandedSites.insert(site.id).inserted { expandedSites.remove(site.id) }
                        }
                    }
                } label: {
                    HStack(spacing: 11) {
                        RelayProviderIcon(kind: site.kind, size: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(site.kind == .workbuddy2api && site.parents.count == 1 ? site.parents[0].name : site.kind.displayName)
                                .font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(siteConsumption(site) + " · \(site.accounts.count) 个账户")
                                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(siteValue(site)).font(.system(size: site.kind == .workbuddy2api ? 11 : 15, weight: .medium))
                            .foregroundStyle(site.kind == .workbuddy2api ? Color.secondary : Color.primary).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .layoutPriority(1)
                            .help(siteValue(site, compact: false))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                }
                .buttonStyle(RelayCardButtonStyle())
                .help(site.address)
                .accessibilityLabel("\(site.kind.displayName)，\(site.address)，\(site.accounts.count) 个账户，\(siteConsumption(site))，\(site.kind == .workbuddy2api ? "可用积分" : "余额") \(siteValue(site, compact: false))")
                .accessibilityValue(site.accounts.count == 1 ? "打开账户详情" : expanded ? "已展开" : "已折叠")
                .accessibilityHint(site.accounts.count == 1 ? "打开账户详情" : "展开或收起此站点的账户")
            }
            .contextMenu {
                if site.accounts.count == 1, let account = site.matchingAccounts.first { accountActions(account) }
            }
            if expanded {
                Divider().padding(.leading, 46).padding(.trailing, 10).opacity(0.5)
                VStack(spacing: 2) {
                    ForEach(site.matchingAccounts) { account in accountRow(account) }
                }
                .padding(.horizontal, 6).padding(.vertical, 5)
                .transition(.opacity)
            }
            if site.warningCount > 0 {
                Label("\(site.warningCount) 个账户需关注", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13).padding(.bottom, 11)
                    .help(site.accounts.compactMap { healthMessage($0) }.joined(separator: "；"))
            }
        }
        .background {
            if expanded {
                RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor))
            }
        }
        .overlay {
            if expanded {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
    }

    private func siteValue(_ site: SiteAccountGroup, compact: Bool = true) -> String {
        if site.kind == .workbuddy2api {
            let credits = store.creditTotal(accountIDs: site.enabledParentIDs)
            return amount(credits.value.map {
                (compact ? RelayNumberFormatter.compactDecimal($0) : RelayNumberFormatter.decimal($0)) + " 积分"
            } ?? "—")
        }
        let total = store.balanceTotal(forAccountIDs: site.enabledParentIDs)
        let value = total.isComplete ? total.value?.amount : nil
        return compact ? compactMoney(value, currency: store.settings.baseCurrency)
            : money(value, currency: store.settings.baseCurrency)
    }

    private func siteConsumption(_ site: SiteAccountGroup) -> String {
        guard site.kind != .workbuddy2api else { return "消耗未提供" }
        let total = store.todaySpendTotal(forAccountIDs: site.enabledParentIDs)
        return "今日消耗 " + money(total.isComplete ? total.value?.amount : nil, currency: store.settings.baseCurrency)
    }

    private func accountValue(_ account: AccountModel, compact: Bool = true) -> String {
        if account.kind == .workbuddy2api {
            return amount(account.availablePoints.map {
                (compact ? RelayNumberFormatter.compactDecimal($0) : RelayNumberFormatter.decimal($0)) + " 积分"
            } ?? "—")
        }
        return compact ? compactMoney(account.balance, currency: account.currency)
            : money(account.balance, currency: account.currency)
    }

    private func expandMatchingSites() {
        guard !accountSearch.isEmpty || accountGroup != nil else { return }
        // Expand when the query changes, but let people collapse any result again.
        expandedSites.formUnion(sites.filter { $0.accounts.count > 1 }.map(\.id))
    }

    private func accountRow(_ account: AccountModel) -> some View {
        HStack(spacing: 3) {
            Button { highlightedAccountID = account.id; onPresentDetail(account) } label: {
                HStack(spacing: 10) {
                    Text(String(account.name.prefix(1)))
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(account.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            if AccountOrganizationService.configuration(for: account, in: store.accountConfigurations)?.isPinned == true {
                                Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                            }
                            if let message = healthMessage(account) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9)).foregroundStyle(statusColor(account.status))
                                    .help(message).accessibilityLabel(message)
                            }
                        }
                        Text(account.kind == .workbuddy2api ? "消耗未提供"
                             : "今日消耗 " + money(account.todaySpend, currency: account.currency))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(accountValue(account))
                        .font(.system(size: 13, weight: .medium)).monospacedDigit().lineLimit(1)
                        .layoutPriority(1).help(accountValue(account, compact: false))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(RelayCardButtonStyle())
            .help(healthPresentation(account).detail)
            .accessibilityLabel("查看 \(account.name) 的详情与走势，\(account.kind == .workbuddy2api ? "可用积分" : "余额") \(accountValue(account, compact: false))")
            .accessibilityValue(healthPresentation(account).detail)
        }
        .foregroundStyle(highlightedAccountID == account.id ? Color.accentColor : Color.primary)
        .background(highlightedAccountID == account.id ? Color.accentColor.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9))
        .contextMenu { accountActions(account) }
    }

    @ViewBuilder private func accountActions(_ account: AccountModel) -> some View {
        Button("查看详情") { onPresentDetail(account) }
        if let parentID = account.parentAccountID, let parent = store.accounts.first(where: { UUID(uuidString: $0.id) == parentID }) {
            Button("编辑所属网关") { onPresentEdit(parent) }
        } else { Button("编辑账户") { onPresentEdit(account) } }
        if let config = AccountOrganizationService.configuration(for: account, in: store.accountConfigurations) {
            Button(config.isPinned ? "取消置顶" : "置顶账户") {
                store.updateAccountPreferences(id: config.id, monthlyBudget: config.monthlyBudget,
                    groupName: config.groupName, isPinned: !config.isPinned)
            }
        }
        Button("立即刷新") {
            guard let id = account.parentAccountID ?? UUID(uuidString: account.id) else { return }
            Task { await store.refresh(accountID: id, forceRateRefresh: true) }
        }
        if account.parentAccountID == nil, let id = UUID(uuidString: account.id) {
            Button(account.isEnabled ? "停用账户" : "启用账户") {
                store.setEnabled(accountID: id, enabled: !account.isEnabled)
            }
            Divider()
            Button("删除账户", role: .destructive) { accountPendingDeletion = account }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: store.isRefreshing ? "arrow.triangle.2.circlepath" : "clock").font(.system(size: 9))
                Text(store.isRefreshing ? "正在刷新" : store.lastSyncedAt.map { "已更新 · " + $0.formatted(date: .omitted, time: .shortened) } ?? "尚未刷新")
                Spacer()
                Text("每 \(max(1, store.settings.refreshIntervalSeconds / 60)) 分钟自动刷新")
            }
            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            Divider().opacity(0.6)
            HStack(spacing: 12) {
                Button(action: onPresentAddAccount) { Label("添加账户", systemImage: "plus") }
                    .buttonStyle(RelaySecondaryCapsuleButtonStyle()).disabled(!store.storageAvailability.isAvailable)
                Spacer()
                Button {
                    if store.isRefreshing { store.cancelRefreshes() }
                    else { Task { await store.refreshAll(forceRateRefresh: true) } }
                } label: { Image(systemName: store.isRefreshing ? "stop" : "arrow.clockwise") }
                .buttonStyle(RelayCircularIconButtonStyle())
                .disabled(!store.storageAvailability.isAvailable)
                .help(store.isRefreshing ? "取消刷新" : "刷新全部账户与汇率")
                .accessibilityLabel(store.isRefreshing ? "取消刷新" : "刷新全部账户")
            }
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
    }

    private var storageState: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(.orange)
            Text("本地数据未能载入").font(.headline)
            Text(store.storageAvailability.message ?? "请稍后重新读取。").font(.callout).foregroundStyle(.secondary)
            Button("重新读取") { store.retryOpeningStorage() }.buttonStyle(RelayPrimaryCapsuleButtonStyle())
            if store.storageAvailability == .unavailable(.corruptData) {
                Button("从备份恢复…") { showStorageRecovery = true }.buttonStyle(RelaySecondaryCapsuleButtonStyle())
            }
        }
        .multilineTextAlignment(.center).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(hidden: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: hidden ? "eye.slash" : "bolt.badge.clock").font(.system(size: 32)).foregroundStyle(.secondary)
            Text(hidden ? "所有账户均已隐藏" : "从一个账户开始").font(.system(size: 20, weight: .semibold))
            Text(hidden ? "账户仍在后台刷新，可在设置的账户管理中取消隐藏。" : "连接 Pipio、DeepSeek 或 workbuddy2api，集中查看余额与用量。凭据仅留在本机。")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(hidden ? "管理账户" : "添加账户", action: hidden ? onPresentSettings : onPresentAddAccount)
                .buttonStyle(RelayPrimaryCapsuleButtonStyle())
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func healthPresentation(_ account: AccountModel) -> AccountHealthPresentation {
        let id = account.parentAccountID ?? UUID(uuidString: account.id)
        return AccountHealthPresentation(account: account, health: id.map { store.health(for: $0) })
    }
    private func healthMessage(_ account: AccountModel) -> String? { healthPresentation(account).summary }
    private func statusColor(_ status: AccountStatus) -> Color {
        switch status { case .ok: return .secondary; case .warning, .retrying: return .orange; case .error: return .red }
    }
}

/// A small, non-interactive overview. Nil days break the path rather than joining unknown data.
private struct RelaySpendSparkline: View {
    let values: [Decimal?]
    var body: some View {
        Canvas { context, size in
            let known = values.compactMap { $0.map { NSDecimalNumber(decimal: $0).doubleValue } }
            guard let low = known.min(), let high = known.max(), values.count > 1 else { return }
            let span = max(high - low, max(abs(high) * 0.1, 1))
            var path = Path()
            var connected = false
            for (index, amount) in values.enumerated() {
                guard let amount else { connected = false; continue }
                let value = NSDecimalNumber(decimal: amount).doubleValue
                let point = CGPoint(x: CGFloat(index) / CGFloat(values.count - 1) * size.width,
                    y: 3 + (1 - (value - low) / span) * (size.height - 6))
                if connected { path.addLine(to: point) } else { path.move(to: point) }
                connected = true
                context.fill(Path(ellipseIn: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)),
                             with: .color(.accentColor))
            }
            context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
