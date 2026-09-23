import AppKit
import SwiftUI

/// 主弹出面板：只展示 RelayStore 的真实本地缓存和刷新结果。
public struct MainPopoverView: View {
    @ObservedObject private var store: RelayStore
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .followSystem
    @State private var accountPendingDeletion: AccountModel?
    @State private var expandedProviders = Set<ProviderKind>()
    private let initialGlobalShortcutConfiguration: GlobalShortcutConfiguration
    private let onApplyGlobalShortcut: ((GlobalShortcutConfiguration) -> GlobalShortcutRegistrationOutcome)?
    private let onPresentAddAccount: () -> Void
    private let onPresentSettings: () -> Void
    private let onPresentDetail: (AccountModel, [DailySpendPoint], [ModelUsageItem]) -> Void
    private let onPresentEdit: (AccountModel) -> Void

    public init(
        store: RelayStore,
        initialGlobalShortcutConfiguration: GlobalShortcutConfiguration = GlobalShortcutConfigurationStore.load(),
        onApplyGlobalShortcut: ((GlobalShortcutConfiguration) -> GlobalShortcutRegistrationOutcome)? = nil,
        onPresentAddAccount: @escaping () -> Void = {},
        onPresentSettings: @escaping () -> Void = {},
        onPresentDetail: @escaping (AccountModel, [DailySpendPoint], [ModelUsageItem]) -> Void = { _, _, _ in },
        onPresentEdit: @escaping (AccountModel) -> Void = { _ in }
    ) {
        self.store = store
        self.initialGlobalShortcutConfiguration = initialGlobalShortcutConfiguration
        self.onApplyGlobalShortcut = onApplyGlobalShortcut
        self.onPresentAddAccount = onPresentAddAccount
        self.onPresentSettings = onPresentSettings
        self.onPresentDetail = onPresentDetail
        self.onPresentEdit = onPresentEdit
    }

    private var totalBalance: Decimal? { store.balanceTotalCNY.value?.amount }

    private var totalTodaySpend: Decimal? {
        guard store.todaySpendTotalCNY.isComplete else { return nil }
        return store.todaySpendTotalCNY.value?.amount
    }

    private var enabledAccountCount: Int { store.accounts.filter { $0.isEnabled && $0.kind != .workbuddy2api }.count }

    private var hasAnyError: Bool {
        store.accounts.contains { account in
            if case .error = account.status { return true }
            return false
        }
    }

    private var preferredColorScheme: ColorScheme? {
        RelayVisualStyle.preferredColorScheme(for: appearanceMode)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            if store.accounts.isEmpty {
                emptyStateView
            } else {
                dashboard
            }

            footer
        }
        .frame(width: 400, height: 520)
        .relayPanelSurface(cornerRadius: RelayVisualStyle.panelCornerRadius)
        .preferredColorScheme(preferredColorScheme)
        .alert("确认删除账号？", isPresented: Binding(
            get: { accountPendingDeletion != nil },
            set: { if !$0 { accountPendingDeletion = nil } }
        )) {
            Button("取消", role: .cancel) { accountPendingDeletion = nil }
            Button("删除", role: .destructive) {
                guard let account = accountPendingDeletion,
                      let id = UUID(uuidString: account.id) else { return }
                accountPendingDeletion = nil
                Task { await store.deleteAccount(id: id) }
            }
        } message: {
            Text("将删除本机账户数据和凭据。已启用同步时，删除标记也会同步到其他设备；其他设备仍需重新录入凭据。")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Relay 额度监控")
                .font(.system(size: 16, weight: .bold))
                .contextMenu {
                    Button(action: onPresentSettings) {
                        Label("设置…", systemImage: "gearshape")
                    }
                    Divider()
                    Button(role: .destructive) {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Label("退出 Relay", systemImage: "power")
                    }
                }

            Spacer(minLength: 8)

            Text("基准: \(store.settings.baseCurrency.rawValue) ¥")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.blue.opacity(0.09), in: Capsule())
                .overlay(Capsule().stroke(.blue.opacity(0.6), lineWidth: 1))

            Button {
                Task { await store.refreshAll(forceRateRefresh: true) }
            } label: {
                Group {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("立即同步并刷新账户级汇率")
        }
        .padding(.horizontal, 20)
        .padding(.top, 17)
        .padding(.bottom, 12)
    }

    private var dashboard: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                if let error = store.globalErrorMessage ?? store.syncErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                } else if hasAnyError {
                    Label("部分账号同步失败，已保留上次成功数据", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                if store.accounts.contains(where: { $0.kind != .workbuddy2api }) {
                    HStack(spacing: 8) {
                        summaryCard(title: "总可用折算余额",
                            value: totalBalance.map { RelayNumberFormatter.money($0, currency: store.settings.baseCurrency) } ?? "--",
                            subtitle: store.balanceTotalCNY.isComplete ? "\(enabledAccountCount) 个账号运行正常" : "部分账号缺少可靠数据或汇率", accent: .primary)
                        summaryCard(title: "今日总消耗",
                            value: totalTodaySpend.map { RelayNumberFormatter.money($0, currency: store.settings.baseCurrency) } ?? "--",
                            subtitle: totalTodaySpend == nil ? "数据不完整，已不参与统计" : "全量统计（已完整）",
                            accent: totalTodaySpend == nil ? .primary : .orange)
                    }
                }
                if store.accounts.contains(where: { $0.kind == .workbuddy2api }) {
                    HStack(spacing: 8) {
                        summaryCard(title: "总可用积分",
                            value: store.creditTotal().value.map { NSDecimalNumber(decimal: $0).stringValue } ?? "--",
                            subtitle: store.creditTotal().isComplete ? "网关内部账号汇总" : "部分网关数据不可用", accent: .primary)
                        summaryCard(title: "今日消耗 / 获取积分", value: "暂不支持",
                            subtitle: "网关未提供可靠的自然日统计", accent: .secondary)
                    }
                }
                ForEach(store.gatewayNotices, id: \.self) { notice in
                    Label(notice, systemImage: "info.circle")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack {
                    Text("已连接账号 (\(store.dashboardAccounts.count))")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }.padding(.top, 4)

                LazyVStack(spacing: 7) {
                    ForEach(ProviderKind.supportedCases, id: \.self) { kind in
                        let grouped = store.dashboardAccounts.filter { $0.kind == kind }
                        if !grouped.isEmpty {
                            providerGroup(kind, accounts: grouped)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 9)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(lastSyncText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button(action: onPresentAddAccount) {
                Label("添加", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(action: onPresentSettings) {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func spendPoints(for account: AccountModel) -> [DailySpendPoint] {
        guard let id = UUID(uuidString: account.id) else { return [] }
        return store.dailyUsage(accountID: id, limit: 7).compactMap { record in
            guard let spend = record.spend else { return nil }
            return DailySpendPoint(
                dateString: record.day.formatted(.dateTime.month(.twoDigits).day(.twoDigits)),
                amount: spend.amount
            )
        }
    }

    private func modelUsages(for account: AccountModel) -> [ModelUsageItem] {
        guard let id = UUID(uuidString: account.id),
              let snapshot = store.snapshots.first(where: { $0.accountID == id }),
              let summaries = snapshot.modelUsages else { return [] }
        return ModelUsageItem.items(from: summaries, currency: account.currency)
    }

    private var lastSyncText: String {
        guard let lastSyncedAt = store.lastSyncedAt else { return "上次同步：尚未同步" }
        return "上次同步：\(lastSyncedAt.formatted(date: .omitted, time: .shortened))"
    }

    private func summaryCard(title: String, value: String, subtitle: String, accent: Color) -> some View {
        VStack(alignment: .center, spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(subtitle)
                .font(.system(size: 9))
                .foregroundStyle(subtitle.contains("运行正常") ? .green : .secondary)
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(11)
        .relayGlassTile(cornerRadius: 12)
    }

    private func providerGroup(_ kind: ProviderKind, accounts: [AccountModel]) -> some View {
        VStack(spacing: 7) {
            Button {
                if !expandedProviders.insert(kind).inserted { expandedProviders.remove(kind) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expandedProviders.contains(kind) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text(kind.rawValue).font(.system(size: 13, weight: .semibold))
                    Text("\(accounts.count) 个账号").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        if kind == .workbuddy2api {
                            Text("积分 " + (store.creditTotal().value.map { NSDecimalNumber(decimal: $0).stringValue } ?? "--"))
                            Text("今日消耗 暂不支持")
                        } else {
                            let balance = store.balanceTotal(for: kind)
                            let today = store.todaySpendTotal(for: kind)
                            Text("余额 " + (balance.value.map { RelayNumberFormatter.money($0.amount, currency: store.settings.baseCurrency) } ?? "--"))
                            Text("今日 " + (today.isComplete ? (today.value.map { RelayNumberFormatter.money($0.amount, currency: store.settings.baseCurrency) } ?? "--") : "--"))
                        }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .padding(11).relayGlassTile(cornerRadius: 11)
                .accessibilityLabel("\(kind.rawValue) 分组，\(accounts.count) 个账号")
            if expandedProviders.contains(kind) {
                ForEach(accounts) { account in accountRow(account).padding(.leading, 12) }
            }
        }
    }

    private func accountRow(_ account: AccountModel) -> some View {
        HStack(spacing: 5) {
            Button {
                onPresentDetail(account, spendPoints(for: account), modelUsages(for: account))
            } label: {
                HStack(spacing: 9) {
                    Circle()
                        .fill(statusColor(for: account.status))
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(account.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(account.kind.rawValue)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                            if let message = statusMessage(for: account.status) {
                                Text(message)
                                    .font(.system(size: 9))
                                    .foregroundStyle(statusColor(for: account.status))
                                    .lineLimit(1)
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(account.kind == .workbuddy2api ? (account.availablePoints.map { "\(NSDecimalNumber(decimal: $0).stringValue) 积分" } ?? "积分 --") : (account.balance.map { RelayNumberFormatter.money($0, currency: account.currency) } ?? "--"))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let todaySpend = account.todaySpend {
                            Text("今日 \(RelayNumberFormatter.money(todaySpend, currency: account.currency))")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看 \(account.name) 的详情与走势")

            Menu {
                Button("查看详情与走势折线图") { onPresentDetail(account, spendPoints(for: account), modelUsages(for: account)) }
                if account.parentAccountID == nil { Button("编辑账号") { onPresentEdit(account) } }
                Button("立即手动同步") {
                    guard let id = account.parentAccountID ?? UUID(uuidString: account.id) else { return }
                    Task { await store.refresh(accountID: id, forceRateRefresh: true) }
                }
                if let id = UUID(uuidString: account.id) {
                    Button(account.isEnabled ? "停用账号" : "启用账号") {
                        store.setEnabled(accountID: id, enabled: !account.isEnabled)
                    }
                }
                if account.parentAccountID == nil {
                    Divider()
                    Button("删除账号", role: .destructive) { accountPendingDeletion = account }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 32)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("账号操作")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 9)
        .relayGlassTile(cornerRadius: 11)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 58, height: 58)
                Image(systemName: "bolt.badge.clock.fill")
                    .font(.system(size: 25))
                    .foregroundStyle(Color.accentColor)
            }
            Text("尚未接入任何 AI 额度账号")
                .font(.system(size: 15, weight: .bold))
            Text("支持 Pipio、DeepSeek 和 workbuddy2api\n凭据仅保存在本机 Relay 数据目录")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Button(action: onPresentAddAccount) {
                Label("添加首个账号", systemImage: "plus")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusMessage(for status: AccountStatus) -> String? {
        switch status {
        case .ok: return nil
        case .warning(let message), .error(let message): return message
        case .retrying(let seconds): return "\(seconds)s 后重试"
        }
    }

    private func statusColor(for status: AccountStatus) -> Color {
        switch status {
        case .ok: return .green
        case .warning, .retrying: return .yellow
        case .error: return .red
        }
    }
}
