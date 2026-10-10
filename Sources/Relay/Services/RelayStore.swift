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
    @Published public private(set) var transferRevision = 0
    @Published public private(set) var historyBackfillStates: [UUID: HistoryBackfillState] = [:]
    @Published public private(set) var accountHealthStates: [UUID: AccountHealth] = [:]
    @Published public private(set) var accountErrors: [String: String] = [:]
    @Published public private(set) var settings: RelaySettings

    @Published public private(set) var storageAvailability: StorageAvailability = .available
    @Published public private(set) var repositoryErrorMessage: String?
    // Retain a complete, last-successful read for detail pages independently of
    // enabled/hidden dashboard filtering and transient repository failures.
    public private(set) var projectionReloadMilliseconds: Double = 0
    private var detailConfigurations: [AccountConfiguration] = []
    private var detailSnapshots: [ProviderSnapshot] = []
    private var detailHistory: [UUID: [DailyUsageRecord]] = [:]

    private let repository: any LocalRepository
    private let accountService: AccountService
    private let refreshCoordinator: RefreshCoordinator
    private let rateService: RateService
    private let calendar: Calendar
    private let automaticallyRefresh: Bool
    private let backupService: LocalBackupService
    private var activeAccountMutations = 0
    private var expectedAccountIDs: Set<UUID> = []
    private var presentationTask: Task<Void, Never>?
    private var clockObservers: Set<AnyCancellable> = []
    private var refreshLoopTask: Task<Void, Never>?
    private var isApplyingTransferredData = false
    private var syncResolutionInProgress = false
    private var syncReloadPending = false
    private var syncReloadTask: Task<Void, Never>?
    private var pendingLowBalanceNotificationIDs: Set<UUID> = []
    private var pendingBudgetNotificationIDs: Set<UUID> = []
    private var budgetAlertState = BudgetAlertState()
    private var backupTask: Task<Void, Never>?
    @Published public private(set) var backupErrorMessage: String?

    public init(
        repository: any LocalRepository,
        credentialStore: any CredentialStore,
        adapters: ProviderAdapterRegistry,
        rateService: RateService = RateService(),
        calendar: Calendar = .autoupdatingCurrent,
        automaticallyRefresh: Bool = true,
        backupService: LocalBackupService = .shared
    ) {
        if let recoverable = repository as? RecoverableLocalRepository {
            storageAvailability = recoverable.availability
        }
        let initialSettings = (try? repository.settings()) ?? RelaySettings()
        self.backupService = backupService
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
        if let data = UserDefaults.standard.data(forKey: "relay-budget-alert-state"),
           let state = try? JSONDecoder().decode(BudgetAlertState.self, from: data) { budgetAlertState = state }
        self.settings = initialSettings
        refreshCoordinator.onHealthChange = { [weak self] id, state in
            guard let self else { return }
            self.accountHealthStates[id] = state
            self.isRefreshing = self.accountHealthStates.values.contains { $0.phase.isActive }
            self.rebuildHealthProjection()
            if state.phase == .idle {
                self.notifyLowBalanceAccountsIfNeeded()
                self.notifyBudgetAccountsIfNeeded()
            }
        }
        refreshCoordinator.onHistoryBackfillChange = { [weak self] id, state in self?.historyBackfillStates[id] = state }
        refreshCoordinator.onHistoryBackfillCommit = { [weak self] _ in self?.reloadFromRepository() }
        refreshCoordinator.onResult = { [weak self] result in self?.applyRefreshResult(result) }
        refreshCoordinator.onRepositoryError = { [weak self] message in self?.globalErrorMessage = message }
        reloadFromRepository()
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.refreshLoopTask?.cancel()
                self?.presentationTask?.cancel()
                self?.cancelRefreshes()
            }.store(in: &clockObservers)
        if automaticallyRefresh && storageAvailability.isAvailable {
            startAutomaticRefresh(refreshImmediately: true)
            startPresentationUpdates()
        }
    }

    public static func production() throws -> RelayStore {
        let repository = RecoverableLocalRepository { try FileLocalRepository() }
        let credentialStore = FileCredentialStore()
        let rateService = RateService()
        return RelayStore(
            repository: repository,
            credentialStore: credentialStore,
            adapters: .production(),
            rateService: rateService
        )
    }

    /// The same service identity can reopen storage after a startup failure.
    public static func unavailable(_ error: Error) -> RelayStore {
        RelayStore(repository: RecoverableLocalRepository(error: error, open: { try FileLocalRepository() }),
                   credentialStore: FileCredentialStore(), adapters: .production())
    }

    public func retryOpeningStorage() {
        guard let recoverable = repository as? RecoverableLocalRepository, !storageAvailability.isAvailable else { return }
        do {
            try recoverable.retryOpening()
            storageAvailability = recoverable.availability
            reloadFromRepository(synchronize: false)
            guard repositoryErrorMessage == nil else { return }
            startAutomaticRefresh(refreshImmediately: true)
            if automaticallyRefresh { startPresentationUpdates() }
            scheduleSyncReload()
        } catch {
            storageAvailability = recoverable.availability
            repositoryErrorMessage = storageAvailability.message
            globalErrorMessage = storageAvailability.message
        }
    }

    private func requireStorage() throws {
        guard !isApplyingTransferredData else { throw LocalRepositoryError.unavailable }
        if case .unavailable(let error) = storageAvailability { throw error }
    }

    public func addAccount(_ draft: AccountDraft) async throws {
        try requireStorage()
        activeAccountMutations += 1
        defer { activeAccountMutations -= 1 }
        globalErrorMessage = nil
        let account = try await accountService.addAccount(draft)
        accountErrors.removeValue(forKey: account.id.uuidString)
        lastSyncedAt = Date()
        reloadFromRepository()
    }

    public func probe(_ draft: AccountDraft) async throws -> ProviderSnapshot {
        try requireStorage()
        return try await accountService.probe(draft)
    }

    public func refreshAll(forceRateRefresh: Bool = false, source: RefreshSource = .manualAll) async {
        guard storageAvailability.isAvailable, !isApplyingTransferredData else { return }
        globalErrorMessage = nil
        _ = await refreshCoordinator.refreshAll(forceRateRefresh: forceRateRefresh, source: source)
        if !Task.isCancelled { reloadFromRepository() }
    }

    public func refresh(accountID: UUID, forceRateRefresh: Bool = false) async {
        guard storageAvailability.isAvailable, !isApplyingTransferredData else { return }
        let result = await refreshCoordinator.refresh(accountID: accountID, forceRateRefresh: forceRateRefresh)
        // Read failures happen before the coordinator operation/health callback.
        if result.error == .storageUnavailable { applyRefreshResult(result) }
        if !Task.isCancelled && !result.isCancelled { reloadFromRepository() }
    }

    public func cancelRefreshes() {
        refreshCoordinator.cancelAll()
        syncReloadTask?.cancel()
        syncReloadTask = nil
    }

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
        if result.isSuccess {
            notifyLowBalanceAccountsIfNeeded()
            scheduleSyncReload()
        }
    }

    private func scheduleSyncReload() {
        guard storageAvailability.isAvailable, !isApplyingTransferredData else { return }
        if syncReloadTask != nil || syncResolutionInProgress { syncReloadPending = true; return }
        syncReloadTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            repeat {
                self.syncReloadPending = false
                await self.synchronizeFiles()
            } while self.syncReloadPending && !Task.isCancelled
            self.syncReloadTask = nil
        }
    }

    private func synchronizeFiles() async {
        guard storageAvailability.isAvailable, !isApplyingTransferredData else { return }
        guard settings.iCloudFileSyncEnabled else {
            syncStatus = .idle; syncConflictReport = nil; syncErrorMessage = nil
            return
        }
        guard let directory = FileSyncService.configuredDirectoryURL() else {
            syncStatus = .unavailable
            syncErrorMessage = "尚未选择 iCloud 同步文件夹；本机数据仍然可用。"
            return
        }
        syncStatus = .uploading
        do {
            let status = try await FileSyncService.exchangeAsync(repository: repository, directory: directory, isEnabled: { [weak self] in
                guard let self else { return false }
                return self.storageAvailability.isAvailable && self.settings.iCloudFileSyncEnabled &&
                    FileSyncService.configuredDirectoryURL() == directory
            })
            guard !Task.isCancelled else { return }
            syncStatus = status
            syncConflictReport = FileSyncService.lastConflictReport
            syncErrorMessage = status == .conflicted ? "存在待用户处理的同步冲突。" : nil
        } catch {
            guard !Task.isCancelled else { return }
            syncStatus = .failed
            syncConflictReport = FileSyncService.lastConflictReport
            syncErrorMessage = "文件同步失败：" + Self.userFacingMessage(for: error)
        }
        reloadFromRepository(synchronize: false)
        notifyLowBalanceAccountsIfNeeded()
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
    public func resolveSyncConflict(_ decision: SyncConflictDecision) async -> String? {
        guard storageAvailability.isAvailable, !isApplyingTransferredData else { return storageAvailability.message ?? "正在应用导入数据，请稍后。" }
        guard let report = syncConflictReport else {
            let message = SyncConflictError.noPendingConflict.localizedDescription
            syncErrorMessage = message
            return message
        }
        guard !syncResolutionInProgress else { return "正在处理同步冲突，请稍候。" }
        syncResolutionInProgress = true
        let previousSync = syncReloadTask
        previousSync?.cancel()
        await previousSync?.value
        syncReloadTask = nil
        defer {
            syncResolutionInProgress = false
            if syncReloadPending { scheduleSyncReload() }
        }
        do {
            try await FileSyncService.resolveAsync(repository: repository, report: report, decision: decision,
                                                   isEnabled: { [weak self] in self?.storageAvailability.isAvailable == true })
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
        guard storageAvailability.isAvailable, !isApplyingTransferredData else { return }
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
        guard storageAvailability.isAvailable, !isApplyingTransferredData else { return }
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
        guard storageAvailability.isAvailable, !isApplyingTransferredData else { return }
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
        try requireStorage()
        activeAccountMutations += 1
        defer { activeAccountMutations -= 1 }
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
        guard storageAvailability.isAvailable, !isApplyingTransferredData else { return }
        do {
            try repository.updateSettings(newSettings)
            globalErrorMessage = nil
            reloadFromRepository()
        } catch {
            globalErrorMessage = Self.userFacingMessage(for: error)
        }
    }

    public func startHistoryBackfill(accountID: UUID, days: Int) {
        guard storageAvailability.isAvailable, !isApplyingTransferredData else { return }
        refreshCoordinator.startHistoryBackfill(accountID: accountID, days: days)
    }

    public func cancelHistoryBackfill(accountID: UUID) {
        refreshCoordinator.cancelHistoryBackfill(accountID: accountID)
    }

    public func transferSnapshot() throws -> RelaySyncData {
        guard storageAvailability.isAvailable, !isApplyingTransferredData else { throw LocalRepositoryError.unavailable }
        return try repository.syncData()
    }

    public func importConfiguration(_ preview: ConfigurationImportPreview, expectedLocal: RelaySyncData) async throws {
        let bytes = try DataTransferService.exportConfiguration(RelaySyncData(accounts: preview.archive.accounts, snapshots: [], dailyUsage: [], settings: preview.archive.settings))
        let validated = try DataTransferService.previewConfiguration(bytes, existingAccountIDs: Set(expectedLocal.accounts.map(\.id)))
        var accounts = expectedLocal.accounts
        for imported in validated.archive.accounts {
            if let index = accounts.firstIndex(where: { $0.id == imported.id }) { accounts[index] = imported }
            else { accounts.append(imported) }
        }
        var tombstones = expectedLocal.deletedAccountIDs
        for account in validated.archive.accounts { tombstones.removeValue(forKey: account.id) }
        let changedDestinations = Set(validated.archive.accounts.filter { imported in
            expectedLocal.accounts.contains { $0.id == imported.id && ($0.providerKind != imported.providerKind || $0.siteOrigin != imported.siteOrigin) }
        }.map(\.id))
        let candidate = RelaySyncData(accounts: accounts, snapshots: expectedLocal.snapshots.filter { !changedDestinations.contains($0.accountID) },
            dailyUsage: expectedLocal.dailyUsage.filter { !changedDestinations.contains($0.accountID) }, settings: validated.archive.settings,
            settingsUpdatedAt: Date(), deletedAccountIDs: tombstones)
        try await applyTransferredData(candidate, expected: expectedLocal, configurationIDs: Set(validated.archive.accounts.map(\.id)))
    }

    public func restoreBackup(_ preview: LocalBackupPreview, expectedLocal: RelaySyncData) async throws {
        let validated = try DataTransferService.decodeBackup(DataTransferService.exportBackup(preview.data))
        try await applyTransferredData(validated, expected: expectedLocal, configurationIDs: Set(validated.accounts.map(\.id)))
    }

    private func applyTransferredData(_ source: RelaySyncData, expected: RelaySyncData, configurationIDs: Set<UUID>) async throws {
        try requireStorage()
        guard activeAccountMutations == 0, !syncResolutionInProgress else { throw DataTransferError.operationInProgress }
        guard try repository.syncData().hasSameContent(as: expected) else { throw DataTransferError.stalePreview }
        isApplyingTransferredData = true
        refreshLoopTask?.cancel()
        refreshLoopTask = nil
        refreshCoordinator.cancelAll()
        let pendingSync = syncReloadTask
        pendingSync?.cancel()
        syncReloadTask = nil
        syncReloadPending = false
        defer {
            isApplyingTransferredData = false
            startAutomaticRefresh()
        }
        await pendingSync?.value
        guard try repository.syncData().hasSameContent(as: expected) else { throw DataTransferError.stalePreview }
        // Saving a recovery point must succeed before any existing data is replaced.
        _ = try await backupService.create(expected)
        guard try repository.syncData().hasSameContent(as: expected) else { throw DataTransferError.stalePreview }
        let existing = Dictionary(uniqueKeysWithValues: expected.accounts.map { ($0.id, $0) })
        let now = Date()
        let configurations = source.accounts.map { original -> AccountConfiguration in
            var account = original
            if let local = existing[account.id], local.providerKind == account.providerKind, local.siteOrigin == account.siteOrigin {
                account.credentialReference = local.credentialReference
            } else {
                // A changed destination must never receive a credential saved for another origin.
                account.credentialReference = UUID().uuidString
            }
            if configurationIDs.contains(account.id) {
                account.updatedAt = Date(timeIntervalSince1970: max(floor(now.timeIntervalSince1970),
                    (existing[account.id]?.updatedAt.timeIntervalSince1970 ?? 0) + 1,
                    (expected.deletedAccountIDs[account.id]?.timeIntervalSince1970 ?? 0) + 1,
                    account.updatedAt.timeIntervalSince1970 + 1))
            }
            return account
        }
        var preferences = source.settings
        preferences.iCloudFileSyncEnabled = expected.settings.iCloudFileSyncEnabled
        let validIDs = Set(configurations.map(\.id))
        var tombstones = expected.deletedAccountIDs.merging(source.deletedAccountIDs, uniquingKeysWith: max)
        for removed in expected.accounts where !validIDs.contains(removed.id) {
            tombstones[removed.id] = Date(timeIntervalSince1970: max(floor(now.timeIntervalSince1970), removed.updatedAt.timeIntervalSince1970 + 1))
        }
        for restored in configurations { tombstones.removeValue(forKey: restored.id) }
        let candidate = RelaySyncData(accounts: configurations,
            snapshots: source.snapshots.filter { validIDs.contains($0.accountID) },
            dailyUsage: source.dailyUsage.filter { validIDs.contains($0.accountID) },
            settings: preferences, settingsUpdatedAt: Date(timeIntervalSince1970: max(floor(now.timeIntervalSince1970), (expected.settingsUpdatedAt?.timeIntervalSince1970 ?? 0) + 1)),
            deletedAccountIDs: tombstones)
        guard try repository.replaceNonsecretData(candidate, expected: expected) else { throw DataTransferError.stalePreview }
        reloadFromRepository(synchronize: false)
        transferRevision += 1
        // Restoration is local. The next normal synchronization still uses conflict protection.
    }

    public var accountConfigurations: [AccountConfiguration] { detailConfigurations }

    public func accountConfiguration(id: UUID) -> AccountConfiguration? {
        detailConfigurations.first { $0.id == id }
    }

    @discardableResult
    public func updateAccountPreferences(id: UUID, monthlyBudget: MoneyValue?, groupName: String?, isPinned: Bool) -> String? {
        guard storageAvailability.isAvailable, !isApplyingTransferredData else { return storageAvailability.message ?? "正在应用导入数据，请稍后。" }
        if let monthlyBudget, monthlyBudget.amount.isNaN || monthlyBudget.amount <= 0 {
            return "月预算必须是大于 0 的金额。"
        }
        do {
            guard var account = try repository.account(id: id) else { return "账户已移除。" }
            let group = groupName?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (group?.count ?? 0) <= 40 else { return "分组名称最多 40 个字符。" }
            account.monthlyBudget = monthlyBudget
            account.groupName = group?.isEmpty == false ? group : nil
            account.isPinned = isPinned
            account.updatedAt = Date(timeIntervalSince1970: max(floor(Date().timeIntervalSince1970), account.updatedAt.timeIntervalSince1970 + 1))
            try repository.upsertAccount(account)
            reloadFromRepository()
            return nil
        } catch { return Self.userFacingMessage(for: error) }
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
        try requireStorage()
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
            guard account.isEnabled, !account.isHidden else { return false }
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
        guard automaticallyRefresh && storageAvailability.isAvailable && !isApplyingTransferredData else { return }
        refreshLoopTask?.cancel()
        let interval = UInt64(max(60, settings.refreshIntervalSeconds)) * 1_000_000_000
        refreshLoopTask = Task { @MainActor [weak self] in
            if refreshImmediately { self?.enqueueAutomaticRefreshes() }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
                guard !Task.isCancelled, self != nil else { return }
                self?.enqueueAutomaticRefreshes()
            }
        }
    }

    private func enqueueAutomaticRefreshes() {
        guard automaticallyRefresh && storageAvailability.isAvailable && !isApplyingTransferredData else { return }
        refreshCoordinator.enqueueScheduledRefreshes(interval: Double(max(60, settings.refreshIntervalSeconds)))
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
                self?.enqueueAutomaticRefreshes()
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
                self?.enqueueAutomaticRefreshes()
            }.store(in: &clockObservers)
        }
    }

    deinit {
        refreshLoopTask?.cancel()
        presentationTask?.cancel()
        syncReloadTask?.cancel()
    }

    private func reloadFromRepository(synchronize: Bool = true, now: Date = Date()) {
        let started = RepositoryPerformanceClock.now()
        defer { projectionReloadMilliseconds = RepositoryPerformanceClock.elapsedMilliseconds(since: started) }
        guard storageAvailability.isAvailable else {
            repositoryErrorMessage = storageAvailability.message
            globalErrorMessage = storageAvailability.message
            syncStatus = .unavailable
            return
        }
        do {
            // Publish the local projection immediately; file exchange runs serially off-actor.
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
            scheduleAutomaticBackup()
            if synchronize {
                notifyBudgetAccountsIfNeeded()
                notifyLowBalanceAccountsIfNeeded()
                scheduleSyncReload()
            }
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

    private func scheduleAutomaticBackup() {
        guard automaticallyRefresh, storageAvailability.isAvailable, !isApplyingTransferredData,
              backupTask == nil, let data = try? repository.syncData(), !data.accounts.isEmpty else { return }
        backupTask = Task { @MainActor [weak self] in
            defer { self?.backupTask = nil }
            do {
                _ = try await self?.backupService.createIfNeeded(data)
                self?.backupErrorMessage = nil
            } catch { self?.backupErrorMessage = "本机备份未能保存：" + error.localizedDescription }
        }
    }

    private func nextBudgetEvent(for id: UUID, at now: Date) -> BudgetAlertEvent? {
        guard let account = detailConfigurations.first(where: { $0.id == id }), account.isEnabled, !account.isHidden,
              let snapshot = detailSnapshots.first(where: { $0.accountID == id }),
              now.timeIntervalSince(snapshot.fetchedAt) <= Double(max(120, settings.refreshIntervalSeconds * 2)),
              snapshot.fetchedAt <= now.addingTimeInterval(60) else { return nil }
        return BudgetService.nextAlert(accountID: id, accountName: account.displayName,
            isEnabled: account.isEnabled, budget: account.monthlyBudget, snapshot: snapshot,
            state: budgetAlertState, now: now, calendar: BudgetService.calendar(for: account.providerKind, fallback: calendar))
    }

    private func notifyBudgetAccountsIfNeeded() {
        guard automaticallyRefresh, storageAvailability.isAvailable, !isApplyingTransferredData,
              UserDefaults.standard.bool(forKey: "budgetNotificationsEnabled") else { return }
        let events = detailConfigurations.compactMap { account -> BudgetAlertEvent? in
            guard !pendingBudgetNotificationIDs.contains(account.id) else { return nil }
            return nextBudgetEvent(for: account.id, at: Date())
        }
        for event in events {
            pendingBudgetNotificationIDs.insert(event.key.accountID)
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.pendingBudgetNotificationIDs.remove(event.key.accountID) }
                let center = UNUserNotificationCenter.current()
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true,
                      UserDefaults.standard.bool(forKey: "budgetNotificationsEnabled"),
                      !self.isApplyingTransferredData,
                      let current = self.nextBudgetEvent(for: event.key.accountID, at: Date()), current.key == event.key else { return }
                let content = UNMutableNotificationContent()
                content.title = current.title
                content.body = current.message
                content.sound = .default
                do {
                    try await center.add(UNNotificationRequest(identifier: current.notificationIdentifier, content: content, trigger: nil))
                    self.budgetAlertState.markDelivered(current)
                    let provider = self.accountConfiguration(id: current.key.accountID)?.providerKind ?? .pipio
                    self.budgetAlertState.retain(month: BudgetService.monthKey(at: Date(), calendar: BudgetService.calendar(for: provider, fallback: self.calendar)), accountID: current.key.accountID)
                    if let bytes = try? JSONEncoder().encode(self.budgetAlertState) { UserDefaults.standard.set(bytes, forKey: "relay-budget-alert-state") }
                } catch { /* Keep the threshold eligible for a later successful refresh. */ }
            }
        }
    }

    private func notifyLowBalanceAccountsIfNeeded() {
        guard storageAvailability.isAvailable, !isApplyingTransferredData else { return }
        guard UserDefaults.standard.bool(forKey: "lowBalanceNotificationsEnabled") else { return }
        let today = calendar.startOfDay(for: Date())
        let lowBalanceAccounts = accounts.filter { account in
            guard account.isEnabled, !account.isHidden else { return false }
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
            for (_, id) in pending {
                guard self.storageAvailability.isAvailable,
                      UserDefaults.standard.bool(forKey: "lowBalanceNotificationsEnabled"),
                      self.calendar.isDate(Date(), inSameDayAs: today),
                      self.storedLowBalanceNotificationDate(for: id) != today,
                      let account = self.accounts.first(where: { $0.id == id.uuidString }),
                      account.isEnabled, !account.isHidden,
                      let threshold = account.lowBalanceThreshold, let balance = account.balance,
                      balance < threshold else { continue }
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
