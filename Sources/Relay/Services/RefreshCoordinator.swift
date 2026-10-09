import Foundation

public struct AccountRefreshResult: Sendable {
    public let accountID: UUID
    public let snapshot: ProviderSnapshot?
    public let error: ProviderError?
    public let isCancelled: Bool
    public var isSuccess: Bool { snapshot != nil && error == nil && !isCancelled }
    public init(accountID: UUID, snapshot: ProviderSnapshot?, error: ProviderError?, isCancelled: Bool = false) {
        self.accountID = accountID; self.snapshot = snapshot; self.error = error; self.isCancelled = isCancelled
    }
    public static func cancelled(_ id: UUID) -> Self {
        Self(accountID: id, snapshot: nil, error: nil, isCancelled: true)
    }
}

@MainActor
public final class RefreshCoordinator {
    private let repository: any LocalRepository
    private let credentialStore: any CredentialStore
    private let adapters: ProviderAdapterRegistry
    private let rateService: RateService
    private let calendar: Calendar
    private let maxRetryCount: Int
    private let clock: RefreshClock
    private let maxConcurrentAccounts: Int
    public private(set) var health: [UUID: AccountHealth] = [:]
    public var onHealthChange: ((UUID, AccountHealth) -> Void)?
    public var onResult: ((AccountRefreshResult) -> Void)?
    public var onRepositoryError: ((String) -> Void)?
    private lazy var scheduler: RefreshScheduler = {
        let scheduler = RefreshScheduler(maxConcurrentAccounts: maxConcurrentAccounts, clock: clock) { [weak self] account, force in
            guard let self else { return .cancelled(account.id) }
            return await self.execute(account: account, forceRateRefresh: force)
        }
        scheduler.onPhaseChange = { [weak self] id, phase in
            self?.updateHealth(id) {
                $0.phase = phase
                if case .backingOff(let until) = phase { $0.issue = .rateLimit; $0.retryAt = until }
            }
        }
        return scheduler
    }()

    public init(
        repository: any LocalRepository,
        credentialStore: any CredentialStore,
        adapters: ProviderAdapterRegistry,
        rateService: RateService = RateService(),
        calendar: Calendar = .current,
        maxRetryCount: Int = 2,
        maxConcurrentAccounts: Int = 3,
        clock: RefreshClock? = nil
    ) {
        self.repository = repository
        self.credentialStore = credentialStore
        self.adapters = adapters
        self.rateService = rateService
        self.calendar = calendar
        self.maxRetryCount = max(0, maxRetryCount)
        self.maxConcurrentAccounts = max(1, maxConcurrentAccounts)
        self.clock = clock ?? RefreshClock()
    }

    public func refreshAll(forceRateRefresh: Bool = false, source: RefreshSource = .manualAll) async -> [AccountRefreshResult] {
        let accounts: [AccountConfiguration]
        do { accounts = try repository.fetchAccounts().filter(\.isEnabled) }
        catch { onRepositoryError?("无法读取账户列表，保留上次成功数据。"); return [] }
        return await withTaskGroup(of: AccountRefreshResult.self) { group in
            for account in accounts {
                group.addTask { await self.scheduler.refresh(account: account, forceRateRefresh: forceRateRefresh, source: source) }
            }
            var results: [UUID: AccountRefreshResult] = [:]
            for await result in group { results[result.accountID] = result }
            return accounts.compactMap { results[$0.id] }
        }
    }

    public func refresh(accountID: UUID, forceRateRefresh: Bool = false, source: RefreshSource = .manualAccount) async -> AccountRefreshResult {
        do {
            guard let account = try repository.account(id: accountID), account.isEnabled else {
                return .cancelled(accountID)
            }
            return await scheduler.refresh(account: account, forceRateRefresh: forceRateRefresh, source: source)
        } catch { return AccountRefreshResult(accountID: accountID, snapshot: nil, error: sanitized(error)) }
    }

    public func cancel(accountID: UUID) { scheduler.cancel(accountID: accountID) }
    public func cancelAll() { scheduler.cancelAll() }

    private func updateHealth(_ id: UUID, _ update: (inout AccountHealth) -> Void) {
        var state = health[id] ?? AccountHealth()
        update(&state)
        health[id] = state
        onHealthChange?(id, state)
    }

    private func restoreFailureState(_ id: UUID, from previous: AccountHealth) {
        updateHealth(id) {
            $0.issue = previous.issue; $0.retryAt = previous.retryAt
            $0.consecutiveFailures = previous.consecutiveFailures
        }
    }

    private func execute(account: AccountConfiguration, forceRateRefresh: Bool) async -> AccountRefreshResult {
        let previousHealth = health[account.id] ?? AccountHealth()
        var attempt = 0
        while true {
            do {
                try Task.checkCancellation()
                updateHealth(account.id) { $0.phase = .refreshing }
                let snapshot = try await performRefresh(account: account, forceRateRefresh: forceRateRefresh)
                updateHealth(account.id) {
                    $0.lastSuccessAt = snapshot.fetchedAt; $0.consecutiveFailures = 0
                    $0.issue = nil; $0.retryAt = nil; $0.freshness = snapshot.freshness
                }
                let result = AccountRefreshResult(accountID: account.id, snapshot: snapshot, error: nil)
                onResult?(result)
                return result
            } catch {
                let providerError = sanitized(error)
                // A received Retry-After remains authoritative even if the request was cancelled.
                let until: Date?
                if case .rateLimited(let retryAfter) = providerError {
                    until = scheduler.recordRateLimit(for: account.siteOrigin, retryAfter: retryAfter)
                } else { until = nil }
                if Task.isCancelled || error is CancellationError || !scheduler.hasInterestedSubscribers(accountID: account.id) {
                    restoreFailureState(account.id, from: previousHealth)
                    return .cancelled(account.id)
                }
                guard attempt < maxRetryCount, isRetryable(providerError) else {
                    updateHealth(account.id) {
                        $0.issue = AccountHealthIssue(error: providerError)
                        $0.consecutiveFailures += 1; $0.retryAt = until
                    }
                    let result = AccountRefreshResult(accountID: account.id, snapshot: nil, error: providerError)
                    onResult?(result)
                    return result
                }
                let delay = until.map { max(0, $0.timeIntervalSince(clock.now())) } ?? retryDelay(for: providerError, attempt: attempt)
                attempt += 1
                updateHealth(account.id) {
                    $0.phase = .backingOff(until: until ?? clock.now().addingTimeInterval(delay))
                    $0.issue = AccountHealthIssue(error: providerError)
                    $0.retryAt = until ?? clock.now().addingTimeInterval(delay)
                }
                do {
                    if let until {
                        while clock.now() < until {
                            try Task.checkCancellation()
                            try await clock.sleep(min(86_400, until.timeIntervalSince(clock.now())))
                        }
                    } else { try await clock.sleep(delay) }
                }
                catch { restoreFailureState(account.id, from: previousHealth); return .cancelled(account.id) }
            }
        }
    }

    private func performRefresh(account: AccountConfiguration, forceRateRefresh: Bool) async throws -> ProviderSnapshot {
        let credential = try await credentialStore.read(reference: account.credentialReference)
        let adapter = try adapters.adapter(for: account.providerKind)
        let oldSnapshot = try repository.snapshot(accountID: account.id)
        let rateResolution = try await rateService.resolve(
            account: account,
            credential: credential,
            adapter: adapter,
            persistedRate: oldSnapshot?.rate,
            forceRefresh: forceRateRefresh
        )
        try Task.checkCancellation()
        let fetched = try await adapter.fetchSnapshot(
            for: account,
            credential: credential,
            rate: rateResolution.rate,
            now: clock.now(),
            calendar: calendar
        )
        try Task.checkCancellation()
        // If an older gateway has no /v1/stats endpoint, keep the previous
        // stats baseline so a later successful response is not counted twice.
        let fetchedWithStats: ProviderSnapshot
        if account.providerKind == .workbuddy2api,
           fetched.workBuddyStats == nil,
           let oldStats = oldSnapshot?.workBuddyStats {
            fetchedWithStats = ProviderSnapshot(
                accountID: fetched.accountID,
                balance: fetched.balance,
                todaySpend: fetched.todaySpend,
                monthSpend: fetched.monthSpend,
                requestCount: fetched.requestCount,
                modelUsages: fetched.modelUsages,
                capabilities: fetched.capabilities,
                freshness: fetched.freshness,
                fetchedAt: fetched.fetchedAt,
                rate: fetched.rate,
                creditMetrics: fetched.creditMetrics,
                subAccounts: fetched.subAccounts,
                workBuddyStats: oldStats
            )
        } else {
            fetchedWithStats = fetched
        }
        let snapshot = rateResolution.isStale ? ProviderSnapshot(
            accountID: fetchedWithStats.accountID,
            balance: fetchedWithStats.balance,
            todaySpend: fetchedWithStats.todaySpend,
            monthSpend: fetchedWithStats.monthSpend,
            requestCount: fetchedWithStats.requestCount,
            modelUsages: fetchedWithStats.modelUsages,
            capabilities: fetchedWithStats.capabilities,
            freshness: .stale,
            fetchedAt: fetchedWithStats.fetchedAt,
            rate: fetchedWithStats.rate,
            creditMetrics: fetchedWithStats.creditMetrics,
            subAccounts: fetchedWithStats.subAccounts,
            workBuddyStats: fetchedWithStats.workBuddyStats
        ) : fetchedWithStats
        var dailyRecord: DailyUsageRecord?
        if account.providerKind == .workbuddy2api, let currentStats = snapshot.workBuddyStats {
            let previousStats = oldSnapshot?.workBuddyStats
            let delta: Decimal
            if let previousStats, previousStats.since == currentStats.since {
                delta = max(currentStats.total.credit - previousStats.total.credit, .zero)
            } else {
                // A changed `since` means the gateway process restarted. The
                // new process starts at zero, so its current total is a new epoch.
                delta = max(currentStats.total.credit, .zero)
            }
            if delta > 0 {
                let day = calendar.startOfDay(for: snapshot.fetchedAt)
                let existing = try repository.dailyUsage(accountID: account.id, limit: nil)
                    .first(where: { calendar.isDate($0.day, inSameDayAs: day) })
                let amount = (existing?.spend?.currency == .cny ? existing?.spend?.amount : nil) ?? .zero
                dailyRecord = DailyUsageRecord(
                    accountID: account.id,
                    day: day,
                    spend: MoneyValue(amount: amount + delta, currency: .cny),
                    updatedAt: snapshot.fetchedAt
                )
            }
        } else if account.providerKind != .workbuddy2api {
            let historyCalendar = account.providerKind == .deepseek
                ? DeepSeekUsageService.historyCalendar
                : calendar
            let day = historyCalendar.startOfDay(for: snapshot.fetchedAt)
            dailyRecord = DailyUsageRecord(accountID: account.id, day: day, spend: snapshot.todaySpend, updatedAt: snapshot.fetchedAt)
        }

        // The cumulative baseline must advance only when its delta is persisted.
        try Task.checkCancellation()
        // Main-actor validation + commit has no suspension: edits/deletion cannot race the write.
        guard scheduler.hasInterestedSubscribers(accountID: account.id),
              let current = try repository.account(id: account.id), current.isEnabled,
              current == account else { throw CancellationError() }
        try repository.commitRefresh(snapshot, dailyUsage: dailyRecord)

        // The seven-day backfill is intentionally performed only during initial
        // account setup. Regular refreshes query and persist the current day so
        // they do not repeatedly request the same historical provider ranges.
        return snapshot
    }

    private func isRetryable(_ error: ProviderError) -> Bool {
        switch error {
        case .transport, .rateLimited: return true
        case .server(let status): return status >= 500 && status < 600
        default: return false
        }
    }

    private func retryDelay(for error: ProviderError, attempt: Int) -> TimeInterval {
        if case .rateLimited(let retryAfter) = error, let retryAfter {
            return RefreshScheduler.safeRetryDelay(retryAfter)
        }
        return min(pow(2, Double(attempt + 1)), 30)
    }

    private func sanitized(_ error: Error) -> ProviderError {
        if let providerError = error as? ProviderError { return providerError }
        if error is LocalRepositoryError { return .storageUnavailable }
        if let credentialError = error as? CredentialStoreError {
            return credentialError == .notFound ? .invalidCredential : .storageUnavailable
        }
        return .transport
    }
}
