import SwiftUI
import AppKit

/// 主弹出面板：只展示 RelayStore 的真实本地缓存和刷新结果。
public struct MainPopoverView: View {
    @ObservedObject private var store: RelayStore
    @State private var showAddModal = false
    @State private var showSettings = false
    @State private var selectedDetailAccount: AccountModel?
    @State private var selectedEditAccount: AccountModel?
    @State private var accountPendingDeletion: AccountModel?

    public init(store: RelayStore) {
        self.store = store
    }

    private var totalBalanceCNY: Decimal? { store.balanceTotalCNY.value?.amount }
    private var totalTodaySpendCNY: Decimal? {
        guard store.todaySpendTotalCNY.isComplete else { return nil }
        return store.todaySpendTotalCNY.value?.amount
    }
    private var hasAnyError: Bool {
        store.accounts.contains { account in
            if case .error = account.status { return true }
            return false
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Relay 额度监控")
                    .font(.system(size: 16, weight: .bold))
                    .contextMenu {
                        Button { showSettings = true } label: {
                            Label("设置…", systemImage: "gearshape")
                        }

                        Divider()

                        Button(role: .destructive) {
                            NSApplication.shared.terminate(nil)
                        } label: {
                            Label("退出 Relay", systemImage: "power")
                        }
                    }
                Spacer()
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button { Task { await store.refreshAll(forceRateRefresh: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("立即同步并刷新账户级汇率")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().opacity(0.3)

            if let error = store.globalErrorMessage ?? store.syncErrorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            if store.accounts.isEmpty {
                emptyStateView
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {
                        if hasAnyError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text("部分账号同步失败，已保留上次成功数据；未知金额不会显示为 0")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.red)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        }

                        HStack(spacing: 10) {
                            summaryCard(
                                title: "总可用折算余额",
                                value: totalBalanceCNY.map { "\(store.settings.baseCurrency.symbol)\($0)" } ?? "--",
                                subtitle: store.balanceTotalCNY.isComplete ? "\(store.accounts.filter(\.isEnabled).count) 个账号已纳入" : "部分账户缺少可靠数据或汇率"
                            )
                            if let todaySpend = totalTodaySpendCNY {
                                summaryCard(
                                    title: "今日总消耗 (已完整)",
                                    value: "\(store.settings.baseCurrency.symbol)\(todaySpend)",
                                    subtitle: "按账户独立汇率折算"
                                )
                            }
                        }

                        ForEach(store.accounts) { account in
                            accountRow(account)
                        }
                    }
                    .padding(12)
                }
            }

            Divider().opacity(0.3)
            HStack {
                Text(lastSyncText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showAddModal = true } label: {
                    Label("添加账号", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 430, height: 560)
        .sheet(isPresented: $showAddModal) {
            AccountAddModalView(
                onDismiss: { showAddModal = false },
                onSave: { draft in
                    try await store.addAccount(draft)
                },
                onProbe: { draft in
                    try await store.probe(draft)
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsWindowView(
                initialSettings: store.settings,
                onClose: { showSettings = false },
                onSave: { store.updateSettings($0) }
            )
        }
        .sheet(item: $selectedDetailAccount) { account in
            AccountDetailView(
                account: UUID(uuidString: account.id).flatMap { store.accountModel(id: $0) } ?? account,
                spendPoints: spendPoints(for: account),
                modelUsages: modelUsages(for: account),
                onClose: { selectedDetailAccount = nil }
            )
        }
        .sheet(item: $selectedEditAccount) { account in
            AccountEditModalView(
                account: account,
                onDismiss: { selectedEditAccount = nil },
                onSave: { name, threshold, credential in
                    guard let id = UUID(uuidString: account.id) else { return }
                    try await store.updateAccount(
                        accountID: id,
                        displayName: name,
                        lowBalanceThreshold: threshold,
                        replacementCredential: credential
                    )
                }
            )
        }
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

    private func spendPoints(for account: AccountModel) -> [DailySpendPoint] {
        guard let id = UUID(uuidString: account.id) else { return [] }
        return store.dailyUsage(accountID: id, limit: 30).compactMap { record in
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
        let priced = summaries.compactMap { summary -> (ModelUsageSummary, Decimal)? in
            guard let spend = summary.spend else { return nil }
            return (summary, spend.amount)
        }
        let total = priced.reduce(Decimal.zero) { $0 + $1.1 }
        guard total > 0 else { return [] }
        return priced.map { summary, cost in
            let tokenText = summary.tokenCount.map { $0.formatted() } ?? "--"
            return ModelUsageItem(
                id: summary.id,
                modelName: summary.modelName,
                tokens: tokenText,
                cost: cost,
                currency: account.currency,
                percentage: NSDecimalNumber(decimal: cost / total).doubleValue
            )
        }
    }

    private var lastSyncText: String {
        guard let lastSyncedAt = store.lastSyncedAt else { return "尚未同步" }
        return "上次同步：\(lastSyncedAt.formatted(date: .omitted, time: .shortened))"
    }

    private func summaryCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.4), lineWidth: 1))
    }

    private func accountRow(_ account: AccountModel) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor(for: account.status))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(account.name).font(.system(size: 12, weight: .semibold))
                    Text(account.kind.rawValue)
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                }
                Text(statusText(account))
                    .font(.system(size: 10))
                    .foregroundStyle(statusColor(for: account.status))
            }

            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(account.balance.map { "\(account.currency.symbol)\($0)" } ?? "--")
                    .font(.system(size: 13, weight: .bold))
                if let todaySpend = account.todaySpend {
                    Text("今日 \(account.currency.symbol)\(todaySpend)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Menu {
                Button("查看详情与走势折线图") { selectedDetailAccount = account }
                Button("编辑账号") { selectedEditAccount = account }
                Button("立即手动同步") {
                    guard let id = UUID(uuidString: account.id) else { return }
                    Task { await store.refresh(accountID: id, forceRateRefresh: true) }
                }
                if let id = UUID(uuidString: account.id) {
                    Button(account.isEnabled ? "停用账号" : "启用账号") {
                        store.setEnabled(accountID: id, enabled: !account.isEnabled)
                    }
                }
                Divider()
                Button("删除账号", role: .destructive) {
                    accountPendingDeletion = account
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(statusColor(for: account.status).opacity(0.35), lineWidth: 1))
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 60, height: 60)
                Image(systemName: "bolt.badge.clock.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
            }
            Text("尚未接入任何 AI 额度账号")
                .font(.system(size: 15, weight: .bold))
            Text("支持 Pipio、DeepSeek 官方 API\n凭据仅保存在本机 Relay 数据目录")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Button { showAddModal = true } label: {
                Label("添加首个账号", systemImage: "plus")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusText(_ account: AccountModel) -> String {
        switch account.status {
        case .ok: return account.baseURL
        case .warning(let message), .error(let message): return "⚠️ \(message)"
        case .retrying(let seconds): return "⚠️ 网络超时，\(seconds)s 后自动重试"
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
