import Foundation

public struct AccountRefreshResult: Sendable {
    public let accountID: UUID
    public let snapshot: ProviderSnapshot?
    public let error: ProviderError?
    public var isSuccess: Bool { snapshot != nil && error == nil }
}

@MainActor
public final class RefreshCoordinator {
    private let repository: any LocalRepository
    private let credentialStore: any CredentialStore
    private let adapters: ProviderAdapterRegistry
    private let rateService: RateService
    private let calendar: Calendar
    private let maxRetryCount: Int

    public init(
        repository: any LocalRepository,
        credentialStore: any CredentialStore,
        adapters: ProviderAdapterRegistry,
        rateService: RateService = RateService(),
        calendar: Calendar = .current,
        maxRetryCount: Int = 2
    ) {
        self.repository = repository
        self.credentialStore = credentialStore
        self.adapters = adapters
        self.rateService = rateService
        self.calendar = calendar
        self.maxRetryCount = max(0, maxRetryCount)
    }

    public func refreshAll(forceRateRefresh: Bool = false) async -> [AccountRefreshResult] {
        let accounts: [AccountConfiguration]
        do { accounts = try repository.fetchAccounts().filter(\.isEnabled) } catch { return [] }

        // Keep account isolation: one failure, including all retries, never aborts others.
        var results: [AccountRefreshResult] = []
        for account in accounts {
            results.append(await refresh(account: account, forceRateRefresh: forceRateRefresh))
        }
        return results
    }

    public func refresh(accountID: UUID, forceRateRefresh: Bool = false) async -> AccountRefreshResult {
        do {
            guard let account = try repository.account(id: accountID), account.isEnabled else {
                return AccountRefreshResult(accountID: accountID, snapshot: nil, error: nil)
            }
            return await refresh(account: account, forceRateRefresh: forceRateRefresh)
        } catch { return AccountRefreshResult(accountID: accountID, snapshot: nil, error: sanitized(error)) }
    }

    private func refresh(account: AccountConfiguration, forceRateRefresh: Bool) async -> AccountRefreshResult {
        var attempt = 0
        while true {
            do {
                let snapshot = try await performRefresh(account: account, forceRateRefresh: forceRateRefresh)
                return AccountRefreshResult(accountID: account.id, snapshot: snapshot, error: nil)
            } catch {
                let providerError = sanitized(error)
                guard attempt < maxRetryCount, isRetryable(providerError) else {
                    // The old snapshot remains untouched on final failure.
                    return AccountRefreshResult(accountID: account.id, snapshot: nil, error: providerError)
                }
                let delay = retryDelay(for: providerError, attempt: attempt)
                attempt += 1
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch {
                    return AccountRefreshResult(accountID: account.id, snapshot: nil, error: .transport)
                }
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
        let fetched = try await adapter.fetchSnapshot(
            for: account,
            credential: credential,
            rate: rateResolution.rate,
            now: Date(),
            calendar: calendar
        )
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
        try repository.upsertSnapshot(snapshot)
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
                try repository.upsertDailyUsage(DailyUsageRecord(
                    accountID: account.id,
                    day: day,
                    spend: MoneyValue(amount: amount + delta, currency: .cny),
                    updatedAt: snapshot.fetchedAt
                ))
            }
        } else if account.providerKind != .workbuddy2api {
            let historyCalendar = account.providerKind == .deepseek
                ? DeepSeekUsageService.historyCalendar
                : calendar
            let day = historyCalendar.startOfDay(for: snapshot.fetchedAt)
            try repository.upsertDailyUsage(DailyUsageRecord(accountID: account.id, day: day, spend: snapshot.todaySpend, updatedAt: snapshot.fetchedAt))
        }

        // The seven-day backfill is intentionally performed only during initial
        // account setup. Regular refreshes query and persist the current day so
        // they do not repeatedly request the same historical provider ranges.
        return snapshot
    }

    private func isRetryable(_ error: ProviderError) -> Bool {
        switch error {
        case .transport, .server, .rateLimited: return true
        default: return false
        }
    }

    private func retryDelay(for error: ProviderError, attempt: Int) -> TimeInterval {
        if case .rateLimited(let retryAfter) = error, let retryAfter {
            return min(max(retryAfter, 1), 60)
        }
        return min(pow(2, Double(attempt + 1)), 30)
    }

    private func sanitized(_ error: Error) -> ProviderError {
        if let providerError = error as? ProviderError { return providerError }
        if error is CredentialStoreError { return .invalidCredential }
        return .transport
    }
}
