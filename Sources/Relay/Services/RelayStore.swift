import Foundation
import SwiftUI
import UserNotifications
import AppKit
import Combine

/// Main-actor application store that connects the UI to the local business layer.
/// It owns no secret values: credentials are read only while a provider request is
/// running and are kept by FileCredentialStore outside of the UI state.
@MainActor
public final class RelayStore: ObservableObject {
    @Published public private(set) var accounts: [AccountModel] = []
    @Published public private(set) var snapshots: [ProviderSnapshot] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastSyncedAt: Date?
    @Published public private(set) var globalErrorMessage: String?
    @Published public private(set) var syncErrorMessage: String?
    @Published public private(set) var syncStatus: SyncStatus = .idle
    @Published public private(set) var syncConflictReport: SyncConflictReport?
    @Published public private(set) var presentationDate = Date()
    @Published public private(set) var accountHealthStates: [UUID: AccountHealth] = [:]
    @Published public private(set) var accountErrors: [String: String] = [:]
    @Published public private(set) var settings: RelaySettings

    @Published public private(set) var repositoryErrorMessage: String?
    // Retain a complete, last-successful read for detail pages independently of
    // enabled/hidden dashboard filtering and transient repository failures.
    private var detailConfigurations: [AccountConfiguration] = []
    private var detailSnapshots: [ProviderSnapshot] = []
    private var detailHistory: [UUID: [DailyUsageRecord]] = [:]

    private let repository: any LocalRepository
    private let accountService: AccountService
    private let refreshCoordinator: RefreshCoordinator
    private let rateService: RateService
    private let calendar: Calendar
    private let automaticallyRefresh: Bool
    private var expectedAccountIDs: Set<UUID> = []
    private var presentationTask: Task<Void, Never>?
    private var clockObservers: Set<AnyCancellable> = []
    private var refreshLoopTask: Task<Void, Never>?
    private var pendingLowBalanceNotificationIDs: Set<UUID> = []

    public init(
        repository: any LocalRepository,
        credentialStore: any CredentialStore,
        adapters: ProviderAdapterRegistry,
        rateService: RateService = RateService(),
        calendar: Calendar = .autoupdatingCurrent,
        automaticallyRefresh: Bool = true
    ) {
        let initialSettings = (try? repository.settings()) ?? RelaySettings()
        self.automaticallyRefresh = automaticallyRefresh
        self.repository = repository
        self.rateService = rateService
        self.calendar = calendar
        self.accountService = AccountService(
            repository: repository,
            credentialStore: credentialStore,
            adapters: adapters,
            rateService: rateService,
            calendar: calendar
        )
        self.refreshCoordinator = RefreshCoordinator(
            repository: repository,
            credentialStore: credentialStore,
            adapters: adapters,
            rateService: rateService,
            calendar: calendar
        )
        self.settings = initialSettings
        refreshCoordinator.onHealthChange = { [weak self] id, state in
            guard let self else { return }
            self.accountHealthStates[id] = state
            self.isRefreshing = self.accountHealthStates.values.contains { $0.phase.isActive }
            self.rebuildHealthProjection()
        }
        refreshCoordinator.onResult = { [weak self] result in self?.applyRefreshResult(result) }
        refreshCoordinator.onRepositoryError = { [weak self] message in self?.globalErrorMessage = message }
        reloadFromRepository()
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.refreshLoopTask?.cancel()
                self?.presentationTask?.cancel()
                self?.cancelRefreshes()
            }.store(in: &clockObservers)
        if automaticallyRefresh {
            startAutomaticRefresh(refreshImmediately: true)
            startPresentationUpdates()
        }
    }

    public static func production() throws -> RelayStore {
        let repository = try FileLocalRepository()
        let credentialStore = FileCredentialStore()
        let rateService = RateService()
        return RelayStore(
            repository: repository,
            credentialStore: credentialStore,
            adapters: .production(),
            rateService: rateService
        )
    }

    /// Creates a usable store when the local database cannot be opened. The UI
    /// remains available and reports the initialization problem instead of
    /// silently displaying fake account data.
    public static func unavailable(_ error: Error) -> RelayStore {
        let repository = InMemoryLocalRepository()
        let store = RelayStore(
            repository: repository,
            credentialStore: UnavailableCredentialStore(),
            adapters: .production()
        )
        store.globalErrorMessage = Self.userFacingMessage(for: error)
        return store
    }

    public func addAccount(_ draft: AccountDraft) async throws {
        globalErrorMessage = nil
        let account = try await accountService.addAccount(draft)
        accountErrors.removeValue(forKey: account.id.uuidString)
        lastSyncedAt = Date()
        reloadFromRepository()
    }

    public func probe(_ draft: AccountDraft) async throws -> ProviderSnapshot {
        try await accountService.probe(draft)
    }

    public func refreshAll(forceRateRefresh: Bool = false, source: RefreshSource = .manualAll) async {
        globalErrorMessage = nil
        _ = await refreshCoordinator.refreshAll(forceRateRefresh: forceRateRefresh, source: source)
        if !Task.isCancelled { reloadFromRepository() }
    }

    public func refresh(accountID: UUID, forceRateRefresh: Bool = false) async {
        let result = await refreshCoordinator.refresh(accountID: accountID, forceRateRefresh: forceRateRefresh)
        // Read failures happen before the coordinator operation/health callback.
        if result.error == .storageUnavailable { applyRefreshResult(result) }
        if !Task.isCancelled && !result.isCancelled { reloadFromRepository() }
    }

    public func cancelRefreshes() { refreshCoordinator.cancelAll() }

    public func health(for accountID: UUID) -> AccountHealth {
        var state = accountHealthStates[accountID] ?? AccountHealth()
        if state.lastSuccessAt == nil, let snapshot = detailSnapshots.first(where: { $0.accountID == accountID }) {
            state.lastSuccessAt = snapshot.fetchedAt
            state.freshness = snapshot.freshness
        }
        if let lastSuccessAt = state.lastSuccessAt,
           presentationDate.timeIntervalSince(lastSuccessAt) > Double(max(120, settings.refreshIntervalSeconds * 2)),
           state.freshness == .fresh { state.freshness = .stale }
        return state
    }

    private func applyRefreshResult(_ result: AccountRefreshResult) {
        guard !result.isCancelled else { return }
        if let error = result.error {
            accountErrors[result.accountID.uuidString] = AccountHealthIssue(error: error).guidance
        } else if let snapshot = result.snapshot {
            accountErrors.removeValue(forKey: result.accountID.uuidString)
            lastSyncedAt = max(lastSyncedAt ?? .distantPast, snapshot.fetchedAt)
        }
        reloadFromRepository(synchronize: false)
    }

    private func rebuildHealthProjection() {
        accounts = detailConfigurations.map { configuration in
            makeAccountModel(configuration: configuration,
                snapshot: detailSnapshots.first(where: { $0.accountID == configuration.id }),
                errorMessage: accountErrors[configuration.id.uuidString], now: presentationDate)
        }
    }

    /// Applies a user's explicit conflict decision. A failed decision leaves
    /// the report visible and keeps local data available for another attempt.
    @discardableResult
    public func resolveSyncConflict(_ decision: SyncConflictDecision) -> String? {
        guard let report = syncConflictReport else {
            let message = SyncConflictError.noPendingConflict.localizedDescription
            syncErrorMessage = message
            return message
        }
        do {
            _ = try FileSyncService.resolve(repository: repository, report: report, decision: decision)
            syncStatus = .merged
            syncConflictReport = nil
            syncErrorMessage = nil
            reloadFromRepository(synchronize: false)
            return nil
        } catch {
            let message = "无法处理同步冲突：" + Self.userFacingMessage(for: error)
            syncStatus = .conflicted
            syncErrorMessage = message
            return message
        }
    }

    public func deleteAccount(id: UUID) async {
        refreshCoordinator.cancel(accountID: id)
        do {
            try await accountService.deleteAccount(id: id)
            accountHealthStates.removeValue(forKey: id)
            accountErrors.removeValue(forKey: id.uuidString)
            globalErrorMessage = nil
            reloadFromRepository()
        } catch {
            globalErrorMessage = Self.userFacingMessage(for: error)
        }
    }

    public func setEnabled(accountID: UUID, enabled: Bool) {
        do {
            try accountService.setEnabled(accountID: accountID, enabled: enabled)
            if !enabled { refreshCoordinator.cancel(accountID: accountID) }
            globalErrorMessage = nil
            reloadFromRepository()
        } catch {
            globalErrorMessage = Self.userFacingMessage(for: error)
        }
    }

    public func setHidden(accountID: UUID, hidden: Bool) {
        do {
            try accountService.setHidden(accountID: accountID, hidden: hidden)
            globalErrorMessage = nil
            reloadFromRepository()
        } catch {
            globalErrorMessage = Self.userFacingMessage(for: error)
        }
    }

    public func updateAccount(
        accountID: UUID,
        displayName: String,
        lowBalanceThreshold: Decimal?,
        replacementCredential: ProviderCredential? = nil,
        replacementBaseURL: String? = nil,
        manualUSDToCNY: ManualExchangeRateUpdate = .unchanged,
        deepSeekUserTokenUpdate: OptionalStringUpdate = .unchanged
    ) async throws {
        refreshCoordinator.cancel(accountID: accountID)
        do {
            try await accountService.updateAccount(
                accountID: accountID,
                displayName: displayName,
                lowBalanceThreshold: lowBalanceThreshold,
                replacementCredential: replacementCredential,
                replacementBaseURL: replacementBaseURL,
                manualUSDToCNY: manualUSDToCNY,
                deepSeekUserTokenUpdate: deepSeekUserTokenUpdate
            )
            accountErrors.removeValue(forKey: accountID.uuidString)
            reloadFromRepository()
        } catch {
            globalErrorMessage = Self.userFacingMessage(for: error)
            throw error
        }
    }

    public func updateSettings(_ newSettings: RelaySettings) {
        do {
            try repository.updateSettings(newSettings)
            globalErrorMessage = nil
            reloadFromRepository()
        } catch {
            globalErrorMessage = Self.userFacingMessage(for: error)
        }
    }

    public func dailyUsage(accountID: UUID, limit: Int? = 30) -> [DailyUsageRecord] {
        (try? repository.dailyUsage(accountID: accountID, limit: limit)) ?? []
    }

    /// Resolve by stable identity on every view update, including gateway children
    /// whose IDs are not UUIDs. History and model usage belong to their parent.
    public func accountDetail(for accountID: String) -> AccountDetailData? {
        let account: AccountModel
        if let parent = accounts.first(where: { $0.id == accountID }) {
            account = parent
        } else {
            guard let snapshot = detailSnapshots.first(where: { $0.subAccounts?.contains(where: { $0.id == accountID }) == true }),
                  let parent = accounts.first(where: { $0.id == snapshot.accountID.uuidString }),
                  let child = snapshot.subAccounts?.first(where: { $0.id == accountID }) else { return nil }
            account = makeSubAccountModel(child, parent: parent)
        }
        guard let snapshotID = account.parentAccountID ?? UUID(uuidString: account.id) else { return nil }
        let points = (detailHistory[snapshotID] ?? []).suffix(7).compactMap { record -> DailySpendPoint? in
            guard let spend = record.spend else { return nil }
            return DailySpendPoint(
                id: record.id,
                dateString: record.day.formatted(.dateTime.month(.twoDigits).day(.twoDigits)),
                amount: spend.amount
            )
        }
        let models = detailSnapshots.first(where: { $0.accountID == snapshotID })?.modelUsages
        return AccountDetailData(
            account: account,
            spendPoints: points,
            modelUsages: models.map { ModelUsageItem.items(from: $0, currency: account.currency) } ?? [],
            deepSeekUsageReport: deepSeekUsageReport(for: snapshotID)
        )
    }

    public func accountDetailState(for accountID: String) -> AccountDetailState {
        let data = accountDetail(for: accountID)
        if let message = repositoryErrorMessage { return .unavailable(data, message: message) }
        return data.map(AccountDetailState.available) ?? .removed
    }

    /// Builds the detail-page projection from the same persisted snapshot and
    /// daily history used by the main popover. Credentials never enter this
    /// projection; the report is only a view model for already-fetched data.
    public func deepSeekUsageReport(for accountID: UUID) -> DeepSeekUsageReport? {
        guard accounts.first(where: { UUID(uuidString: $0.id) == accountID })?.kind == .deepseek,
              let snapshot = detailSnapshots.first(where: { $0.accountID == accountID }) else {
            return nil
        }
        // A fresh balance-only snapshot means no platform token was configured.
        // Do not turn its empty usage fields into a "complete" usage report.
        if snapshot.freshness == .fresh,
           !snapshot.capabilities.contains(.monthlyUsage),
           !snapshot.capabilities.contains(.requestCount),
           !snapshot.capabilities.contains(.modelUsage) {
            return .unsupported(accountID: accountID, reason: .userTokenNotConfigured, fetchedAt: snapshot.fetchedAt)
        }
        let dailyCalendar = DeepSeekUsageService.historyCalendar
        let daily = (detailHistory[accountID] ?? []).suffix(30).map { record in
            DeepSeekDailyUsage(
                day: dailyCalendar.startOfDay(for: record.day),
                spend: record.spend
            )
        }
        let models = snapshot.modelUsages?.map { summary in
            DeepSeekModelUsage(
                modelName: summary.modelName,
                spend: summary.spend,
                tokenCount: summary.tokenCount,
                requestCount: summary.requestCount
            )
        }
        return DeepSeekUsageReport(
            accountID: accountID,
            coverage: snapshot.freshness == .partial ? .partial : .complete,
            daily: daily,
            models: models,
            fetchedAt: snapshot.fetchedAt
        )
    }

    public func accountModel(id: UUID) -> AccountModel? {
        accounts.first(where: { UUID(uuidString: $0.id) == id })
    }

    private var manualExchangeRates: [UUID: Decimal] {
        Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
            guard let id = UUID(uuidString: account.id), let rate = account.manualUSDToCNY else { return nil }
            return (id, rate)
        })
    }

    /// Home projection: gateway configurations remain editable in settings, while
    /// internal gateway accounts are the visible second-level accounts.
    public var dashboardAccounts: [AccountModel] {
        accounts.flatMap { parent -> [AccountModel] in
            guard !parent.isHidden else { return [] }
            guard parent.kind == .workbuddy2api else { return [parent] }
            guard let id = UUID(uuidString: parent.id),
                  let snapshot = snapshots.first(where: { $0.accountID == id }) else { return [] }
            return (snapshot.subAccounts ?? []).map { child in
                makeSubAccountModel(child, parent: parent)
            }
        }
    }

    private func makeSubAccountModel(_ child: ProviderSubAccountSnapshot, parent: AccountModel) -> AccountModel {
        let status: AccountStatus
        if case .error(let message) = parent.status { status = .error("网关同步失败：" + message) }
        else if !parent.isEnabled { status = .warning("网关已停用") }
        else if child.manualDisabled { status = .warning("手动停用") }
        else if child.disabled { status = .warning("系统停用") }
        else if child.cooling { status = .warning("冷却中") }
        else { status = parent.status }
        return AccountModel(
            id: child.id, name: child.displayName, kind: .workbuddy2api,
            baseURL: parent.baseURL, balance: nil, currency: .cny,
            status: status, lastUpdated: child.fetchedAt, isEnabled: parent.isEnabled,
            availablePoints: child.availablePoints, parentAccountID: child.parentAccountID,
            externalID: child.externalID, disabled: child.disabled,
            manualDisabled: child.manualDisabled, cooling: child.cooling
        )
    }

    public var gatewayNotices: [String] {
        accounts.filter { $0.kind == .workbuddy2api && !$0.isHidden }.compactMap { gateway in
            if let error = accountErrors[gateway.id] { return "\(gateway.name)：\(error)" }
            guard let id = UUID(uuidString: gateway.id),
                  let snapshot = snapshots.first(where: { $0.accountID == id }) else {
                return "\(gateway.name)：尚未同步内部账号"
            }
            return snapshot.subAccounts?.isEmpty == true ? "\(gateway.name)：暂无内部账号" : nil
        }
    }

    public func creditTotal(for kind: ProviderKind = .workbuddy2api) -> CreditDashboardTotal {
        let gateways = accounts.filter { $0.kind == kind && $0.isEnabled && !$0.isHidden }
        guard !gateways.isEmpty else { return CreditDashboardTotal(value: nil, isComplete: true) }
        var excluded = Set<UUID>()
        var total = Decimal.zero
        for gateway in gateways {
            guard let id = UUID(uuidString: gateway.id) else { continue }
            guard accountErrors[gateway.id] == nil,
                  let snapshot = snapshots.first(where: { $0.accountID == id }),
                  let children = snapshot.subAccounts,
                  !children.isEmpty,
                  children.allSatisfy({ $0.availablePoints != nil }) else {
                excluded.insert(id)
                continue
            }
            total += children.compactMap(\.availablePoints).reduce(Decimal.zero, +)
        }
        return CreditDashboardTotal(value: excluded.isEmpty ? total : nil,
                                    isComplete: excluded.isEmpty, excludedAccountIDs: excluded)
    }

    public func performSubAccountAction(_ action: ProviderSubAccountAction, parentID: UUID, externalID: String) async throws {
        try await accountService.performSubAccountAction(parentID: parentID, externalID: externalID, action: action)
        await refresh(accountID: parentID)
    }

    public func balanceTotal(for kind: ProviderKind) -> DashboardTotal {
        let ids = Set(accounts.filter { $0.kind == kind && $0.isEnabled && !$0.isHidden }.compactMap { UUID(uuidString: $0.id) })
        return DashboardAggregator.balanceTotal(snapshots: snapshots.filter { ids.contains($0.accountID) },
            targetCurrency: settings.baseCurrency, now: presentationDate, expectedAccountIDs: ids,
            manualUSDToCNY: manualExchangeRates)
    }

    public func todaySpendTotal(for kind: ProviderKind) -> DashboardTotal {
        let ids = Set(accounts.filter { $0.kind == kind && $0.isEnabled && !$0.isHidden }.compactMap { UUID(uuidString: $0.id) })
        return DashboardAggregator.todaySpendTotal(snapshots: snapshots.filter { ids.contains($0.accountID) },
            targetCurrency: settings.baseCurrency, now: presentationDate, expectedAccountIDs: ids,
            calendar: calendar, manualUSDToCNY: manualExchangeRates)
    }

    public var balanceTotalCNY: DashboardTotal {
        DashboardAggregator.balanceTotal(snapshots: snapshots, targetCurrency: settings.baseCurrency, now: presentationDate, expectedAccountIDs: expectedAccountIDs, manualUSDToCNY: manualExchangeRates)
    }

    public var todaySpendTotalCNY: DashboardTotal {
        DashboardAggregator.todaySpendTotal(snapshots: snapshots, targetCurrency: settings.baseCurrency, now: presentationDate, expectedAccountIDs: expectedAccountIDs, calendar: calendar, manualUSDToCNY: manualExchangeRates)
    }

    public var hasLowBalance: Bool {
        accounts.contains { account in
            guard !account.isHidden else { return false }
            if case .warning(let message) = account.status { return message == "余额低于阈值" }
            return false
        }
    }

    public var hasAnyWarning: Bool {
        accounts.contains { account in
            guard !account.isHidden else { return false }
            switch account.status {
            case .ok: return false
            case .warning, .error, .retrying: return true
            }
        }
    }

    private func startAutomaticRefresh(refreshImmediately: Bool = false) {
        guard automaticallyRefresh else { return }
        refreshLoopTask?.cancel()
        let interval = UInt64(max(60, settings.refreshIntervalSeconds)) * 1_000_000_000
        refreshLoopTask = Task { @MainActor [weak self] in
            if refreshImmediately { await self?.refreshAll(source: .scheduled) }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
                guard !Task.isCancelled, self != nil else { return }
                await self?.refreshAll(source: .scheduled)
            }
        }
    }

    /// Invalidate day-scoped values even when offline or provider refresh fails.
    /// Also serves as a deterministic clock seam for regression checks.
    func updateTemporalPresentation(at now: Date) {
        reloadFromRepository(synchronize: false, now: now)
    }

    private func startPresentationUpdates() {
        presentationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let calendar = self?.calendar else { return }
                let now = Date()
                let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(60)
                let delay = max(0.1, min(60, midnight.timeIntervalSince(now)))
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.updateTemporalPresentation(at: Date())
            }
        }
        // Re-evaluate immediately after sleep, activation, or timezone changes.
        let notifications = [
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification),
            NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange),
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
        ]
        for publisher in notifications {
            publisher.receive(on: RunLoop.main).sink { [weak self] _ in
                self?.updateTemporalPresentation(at: Date())
            }.store(in: &clockObservers)
        }
    }

    deinit {
        refreshLoopTask?.cancel()
        presentationTask?.cancel()
    }

    private func reloadFromRepository(synchronize: Bool = true, now: Date = Date()) {
        do {
            if synchronize {
                let syncSettings = try repository.settings()
                if !syncSettings.iCloudFileSyncEnabled {
                    syncStatus = .idle
                    syncConflictReport = nil
                    syncErrorMessage = nil
                } else if !FileSyncService.hasConfiguredDirectory() {
                    syncStatus = .unavailable
                    syncConflictReport = nil
                    syncErrorMessage = "尚未选择 iCloud 同步文件夹；本机数据仍然可用。"
                } else {
                    do {
                        try FileSyncService.exportIfEnabled(repository: repository, settings: syncSettings)
                        syncStatus = FileSyncService.lastSyncStatus
                        syncConflictReport = FileSyncService.lastConflictReport
                        syncErrorMessage = syncStatus == .conflicted ? "存在待用户处理的同步冲突。" : nil
                    } catch {
                        syncStatus = .failed
                        syncConflictReport = FileSyncService.lastConflictReport
                        syncErrorMessage = "文件同步失败：" + Self.userFacingMessage(for: error)
                    }
                }
            }
            // Read AFTER the exchange so remote changes appear in this update.
            let previousInterval = settings.refreshIntervalSeconds
            let loadedSettings = try repository.settings()
            let configurations = try repository.fetchAccounts()
            var loadedSnapshots: [ProviderSnapshot] = []
            var loadedHistory: [UUID: [DailyUsageRecord]] = [:]
            var loadedAccounts: [AccountModel] = []
            for configuration in configurations {
                let snapshot = try repository.snapshot(accountID: configuration.id)
                if let snapshot { loadedSnapshots.append(snapshot) }
                loadedHistory[configuration.id] = try repository.dailyUsage(accountID: configuration.id, limit: 30)
                loadedAccounts.append(makeAccountModel(
                    configuration: configuration,
                    snapshot: snapshot,
                    errorMessage: accountErrors[configuration.id.uuidString],
                    now: now
                ))
            }
            // Publish only after the entire read succeeds; failures cannot look
            // like deletions or discard the last complete detail projection.
            if let previousError = repositoryErrorMessage, globalErrorMessage == previousError {
                globalErrorMessage = nil
            }
            settings = loadedSettings
            presentationDate = now
            expectedAccountIDs = Set(configurations.filter { $0.isEnabled && !$0.isHidden && $0.providerKind != .workbuddy2api }.map(\.id))
            detailConfigurations = configurations
            detailSnapshots = loadedSnapshots
            detailHistory = loadedHistory
            accounts = loadedAccounts
            let enabledIDs = Set(configurations.filter(\.isEnabled).map(\.id))
            snapshots = loadedSnapshots.filter { enabledIDs.contains($0.accountID) }
            repositoryErrorMessage = nil
            if previousInterval != settings.refreshIntervalSeconds { startAutomaticRefresh() }
            if synchronize { notifyLowBalanceAccountsIfNeeded() }
        } catch {
            // The last complete read remains authoritative, but clock-scoped
            // values must still expire while storage is unavailable.
            presentationDate = now
            accounts = detailConfigurations.map { configuration in
                makeAccountModel(
                    configuration: configuration,
                    snapshot: detailSnapshots.first(where: { $0.accountID == configuration.id }),
                    errorMessage: accountErrors[configuration.id.uuidString],
                    now: now
                )
            }
            let message = Self.userFacingMessage(for: error)
            repositoryErrorMessage = message
            globalErrorMessage = message
        }
    }

    private func notifyLowBalanceAccountsIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "lowBalanceNotificationsEnabled") else { return }
        let today = calendar.startOfDay(for: Date())
        let lowBalanceAccounts = accounts.filter { account in
            guard !account.isHidden else { return false }
            if case .warning(let message) = account.status { return message == "余额低于阈值" }
            return false
        }
        let pending = lowBalanceAccounts.compactMap { account -> (AccountModel, UUID)? in
            guard let id = UUID(uuidString: account.id),
                  !pendingLowBalanceNotificationIDs.contains(id),
                  storedLowBalanceNotificationDate(for: id) != today else { return nil }
            return (account, id)
        }
        guard !pending.isEmpty else { return }
        pendingLowBalanceNotificationIDs.formUnion(pending.map(\.1))
        Task { @MainActor [weak self] in
            guard let self else { return }
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else {
                self.pendingLowBalanceNotificationIDs.subtract(pending.map(\.1))
                return
            }
            for (account, id) in pending {
                let content = UNMutableNotificationContent()
                content.title = "Relay 低余额提醒"
                content.body = "账号“\(account.name)”已低于余额阈值。"
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: "relay.low-balance.\(id.uuidString).\(Int(today.timeIntervalSince1970))",
                    content: content,
                    trigger: nil
                )
                do {
                    try await center.add(request)
                    UserDefaults.standard.set(today.timeIntervalSince1970, forKey: lowBalanceNotificationKey(for: id))
                } catch {
                    self.pendingLowBalanceNotificationIDs.remove(id)
                }
            }
            self.pendingLowBalanceNotificationIDs.subtract(pending.map(\.1))
        }
    }

    private func storedLowBalanceNotificationDate(for id: UUID) -> Date? {
        guard let timestamp = UserDefaults.standard.object(forKey: lowBalanceNotificationKey(for: id)) as? Double else { return nil }
        return calendar.startOfDay(for: Date(timeIntervalSince1970: timestamp))
    }

    private func lowBalanceNotificationKey(for id: UUID) -> String {
        "relay.low-balance-notified.\(id.uuidString)"
    }

    private func makeAccountModel(
        configuration: AccountConfiguration,
        snapshot: ProviderSnapshot?,
        errorMessage: String?,
        now: Date
    ) -> AccountModel {
        let status: AccountStatus
        if !configuration.isEnabled {
            status = .warning("已停用")
        } else if accountHealthStates[configuration.id]?.phase.isActive == true {
            let retryAt = accountHealthStates[configuration.id]?.retryAt
            let seconds = retryAt.map { Int(max(0, min(86_400, $0.timeIntervalSince(now)))) } ?? 0
            status = .retrying(seconds: seconds)
        } else if let errorMessage {
            status = .error(errorMessage)
        } else if let snapshot {
            if let threshold = configuration.lowBalanceThreshold,
               let balance = snapshot.balance?.amount, balance < threshold {
                status = .warning("余额低于阈值")
            } else {
                switch snapshot.freshness {
                case .fresh: status = .ok
                case .stale, .partial: status = .warning(snapshot.freshness == .stale ? "使用上次成功数据" : "部分指标不可用")
                }
            }
        } else if !configuration.isEnabled {
            status = .warning("已停用")
        } else {
            status = .warning("尚未同步")
        }

        return AccountModel(
            id: configuration.id.uuidString,
            name: configuration.displayName,
            kind: configuration.providerKind,
            baseURL: configuration.siteOrigin.absoluteString,
            balance: snapshot?.balance?.amount,
            currency: snapshot?.balance?.currency ?? snapshot?.rate.nativeCurrency ?? .cny,
            todaySpend: snapshot?.todaySpend(on: now, calendar: calendar)?.amount,
            monthSpend: snapshot?.monthSpend?.amount,
            status: status,
            lastUpdated: snapshot?.fetchedAt,
            isEnabled: configuration.isEnabled,
            isHidden: configuration.isHidden,
            lowBalanceThreshold: configuration.lowBalanceThreshold,
            manualUSDToCNY: configuration.manualUSDToCNY,
            quotaPerUnit: snapshot?.rate.quotaPerUnit,
            siteUSDToCNY: snapshot?.rate.nativeCurrency == .usd ? snapshot?.rate.conversionToCNY : nil,
            siteRateIsExpired: snapshot?.rate.isExpired(at: now) ?? false
        )
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "本地数据暂时不可用。"
    }
}

/// The normal production path uses FileCredentialStore. This tiny fallback keeps
/// the app launchable if only the non-secret local repository failed to open.
/// It is intentionally file-free and contains no real credential persistence.
private actor UnavailableCredentialStore: CredentialStore {
    func save(_ credential: ProviderCredential, reference: String) async throws {
        throw CredentialStoreError.writeFailed
    }

    func read(reference: String) async throws -> ProviderCredential {
        throw CredentialStoreError.notFound
    }

    func delete(reference: String) async throws {}
}
