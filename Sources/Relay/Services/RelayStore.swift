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
    @Published public private(set) var presentationDate = Date()
    @Published public private(set) var accountErrors: [String: String] = [:]
    @Published public private(set) var settings: RelaySettings

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
        reloadFromRepository()
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
        reloadFromRepository()
    }

    public func probe(_ draft: AccountDraft) async throws -> ProviderSnapshot {
        try await accountService.probe(draft)
    }

    public func refreshAll(forceRateRefresh: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        globalErrorMessage = nil
        defer {
            isRefreshing = false
            lastSyncedAt = Date()
        }

        let results = await refreshCoordinator.refreshAll(forceRateRefresh: forceRateRefresh)
        for result in results {
            if let error = result.error {
                accountErrors[result.accountID.uuidString] = error.localizedDescription
            } else {
                accountErrors.removeValue(forKey: result.accountID.uuidString)
            }
        }
        reloadFromRepository()
    }

    public func refresh(accountID: UUID, forceRateRefresh: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastSyncedAt = Date()
        }

        let result = await refreshCoordinator.refresh(accountID: accountID, forceRateRefresh: forceRateRefresh)
        if let error = result.error {
            accountErrors[accountID.uuidString] = error.localizedDescription
        } else {
            accountErrors.removeValue(forKey: accountID.uuidString)
        }
        reloadFromRepository()
    }

    public func deleteAccount(id: UUID) async {
        do {
            try await accountService.deleteAccount(id: id)
            accountErrors.removeValue(forKey: id.uuidString)
            reloadFromRepository()
        } catch {
            globalErrorMessage = Self.userFacingMessage(for: error)
        }
    }

    public func setEnabled(accountID: UUID, enabled: Bool) {
        do {
            try accountService.setEnabled(accountID: accountID, enabled: enabled)
            reloadFromRepository()
        } catch {
            globalErrorMessage = Self.userFacingMessage(for: error)
        }
    }

    public func updateAccount(
        accountID: UUID,
        displayName: String,
        lowBalanceThreshold: Decimal?,
        replacementCredential: ProviderCredential? = nil
    ) async throws {
        do {
            try await accountService.updateAccount(
                accountID: accountID,
                displayName: displayName,
                lowBalanceThreshold: lowBalanceThreshold,
                replacementCredential: replacementCredential
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

    public func dailyUsage(accountID: UUID, limit: Int = 30) -> [DailyUsageRecord] {
        (try? repository.dailyUsage(accountID: accountID, limit: limit)) ?? []
    }

    public func accountModel(id: UUID) -> AccountModel? {
        accounts.first(where: { UUID(uuidString: $0.id) == id })
    }

    public var balanceTotalCNY: DashboardTotal {
        DashboardAggregator.balanceTotal(snapshots: snapshots, targetCurrency: settings.baseCurrency, now: presentationDate, expectedAccountIDs: expectedAccountIDs)
    }

    public var todaySpendTotalCNY: DashboardTotal {
        DashboardAggregator.todaySpendTotal(snapshots: snapshots, targetCurrency: settings.baseCurrency, now: presentationDate, expectedAccountIDs: expectedAccountIDs, calendar: calendar)
    }

    public var hasLowBalance: Bool {
        accounts.contains { account in
            if case .warning(let message) = account.status { return message == "余额低于阈值" }
            return false
        }
    }

    public var hasAnyWarning: Bool {
        accounts.contains { account in
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
            if refreshImmediately { await self?.refreshAll() }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
                guard !Task.isCancelled, self != nil else { return }
                await self?.refreshAll()
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
                do {
                    try FileSyncService.exportIfEnabled(repository: repository, settings: repository.settings())
                    syncErrorMessage = nil
                } catch {
                    syncErrorMessage = "文件同步失败：" + Self.userFacingMessage(for: error)
                }
            }
            // Read AFTER the exchange so remote changes appear in this update.
            let previousInterval = settings.refreshIntervalSeconds
            settings = try repository.settings()
            let configurations = try repository.fetchAccounts()
            expectedAccountIDs = Set(configurations.filter(\.isEnabled).map(\.id))
            var loadedSnapshots: [ProviderSnapshot] = []
            presentationDate = now
            accounts = configurations.map { configuration in
                let snapshot: ProviderSnapshot?
                do {
                    snapshot = try repository.snapshot(accountID: configuration.id)
                } catch {
                    snapshot = nil
                    accountErrors[configuration.id.uuidString] = Self.userFacingMessage(for: error)
                }
                if configuration.isEnabled, let snapshot { loadedSnapshots.append(snapshot) }
                return makeAccountModel(
                    configuration: configuration,
                    snapshot: snapshot,
                    errorMessage: accountErrors[configuration.id.uuidString]
                )
            }
            snapshots = loadedSnapshots
            if previousInterval != settings.refreshIntervalSeconds { startAutomaticRefresh() }
            if synchronize { notifyLowBalanceAccountsIfNeeded() }
        } catch {
            accounts = []
            snapshots = []
            expectedAccountIDs = []
            globalErrorMessage = Self.userFacingMessage(for: error)
        }
    }

    private func notifyLowBalanceAccountsIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "lowBalanceNotificationsEnabled") else { return }
        let today = calendar.startOfDay(for: Date())
        let lowBalanceAccounts = accounts.filter { account in
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
        errorMessage: String?
    ) -> AccountModel {
        let status: AccountStatus
        if let errorMessage {
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
            todaySpend: snapshot?.todaySpend(on: presentationDate, calendar: calendar)?.amount,
            monthSpend: snapshot?.monthSpend?.amount,
            status: status,
            lastUpdated: snapshot?.fetchedAt,
            isEnabled: configuration.isEnabled,
            lowBalanceThreshold: configuration.lowBalanceThreshold
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
