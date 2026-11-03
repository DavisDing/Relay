import Foundation

public struct RateResolution: Sendable, Equatable {
    public let rate: AccountRate
    public let isStale: Bool
}

/// Account-scoped rate cache. There is intentionally no provider- or host-level
/// cache because two accounts can have different pricing/rate configurations.
public actor RateService {
    private var cachedRates: [UUID: AccountRate] = [:]
    private var failedRefreshes: Set<UUID> = []

    public init() {}

    public func seed(_ rate: AccountRate) {
        cachedRates[rate.accountID] = rate
        failedRefreshes.remove(rate.accountID)
    }

    public func cachedRate(accountID: UUID) -> AccountRate? {
        cachedRates[accountID]
    }

    public func resolve(
        account: AccountConfiguration,
        credential: ProviderCredential,
        adapter: any ProviderAdapter,
        persistedRate: AccountRate?,
        persistedRateIsStale: Bool = false,
        forceRefresh: Bool,
        refreshInterval: RateRefreshInterval? = nil,
        calendar: Calendar = .current,
        now: Date = Date()
    ) async throws -> RateResolution {
        let previous = cachedRates[account.id] ?? persistedRate
        if cachedRates[account.id] == nil, persistedRateIsStale { failedRefreshes.insert(account.id) }
        let candidate = previous.map { applying(refreshInterval, to: $0, calendar: calendar) }
        let needsPipioDisplayRate = candidate.map {
            $0.source == .pipioAccountStatus && ($0.nativeCurrency != .cny || $0.amountMultiplier == nil)
        } ?? false
        if !forceRefresh, !needsPipioDisplayRate,
           let candidate, refreshInterval == .manual || (!candidate.isExpired(at: now) && !failedRefreshes.contains(account.id)) {
            cachedRates[account.id] = candidate
            return RateResolution(rate: candidate, isStale: candidate.isExpired(at: now) || failedRefreshes.contains(account.id))
        }

        do {
            let fetched = try await adapter.fetchAccountRate(for: account, credential: credential)
            try Task.checkCancellation()
            let fresh = applying(refreshInterval, to: fetched, calendar: calendar)
            guard fresh.accountID == account.id else { throw ProviderError.missingRate }
            cachedRates[account.id] = fresh
            failedRefreshes.remove(account.id)
            return RateResolution(rate: fresh, isStale: false)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let providerError = error as? ProviderError, case .rateLimited = providerError { throw providerError }
            if let candidate, !needsPipioDisplayRate {
                cachedRates[account.id] = candidate
                failedRefreshes.insert(account.id)
                return RateResolution(rate: candidate, isStale: true)
            }
            throw error
        }
    }

    /// Recompute the due date from the original fetch, so changing the setting
    /// takes effect for persisted/cache entries without resetting their age.
    private func applying(_ interval: RateRefreshInterval?, to rate: AccountRate, calendar: Calendar) -> AccountRate {
        guard let interval else { return rate }
        return rate.applying(interval, calendar: calendar)
    }

    public func remove(accountID: UUID) {
        cachedRates.removeValue(forKey: accountID)
        failedRefreshes.remove(accountID)
    }
}
