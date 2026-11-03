import Foundation

public struct RateResolution: Sendable, Equatable {
    public let rate: AccountRate
    public let isStale: Bool
    public let refreshFailed: Bool

    public init(rate: AccountRate, isStale: Bool, refreshFailed: Bool = false) {
        self.rate = rate
        self.isStale = isStale
        self.refreshFailed = refreshFailed
    }
}

/// Account-scoped rate cache. There is intentionally no provider- or host-level
/// cache because two accounts can have different pricing/rate configurations.
public actor RateService {
    private var cachedRates: [UUID: AccountRate] = [:]
    private var pendingRetries: Set<UUID> = []

    public init() {}

    public func seed(_ rate: AccountRate) {
        cachedRates[rate.accountID] = rate
        pendingRetries.remove(rate.accountID)
    }

    public func cachedRate(accountID: UUID) -> AccountRate? {
        cachedRates[accountID]
    }

    public func resolve(
        account: AccountConfiguration,
        credential: ProviderCredential,
        adapter: any ProviderAdapter,
        persistedRate: AccountRate?,
        forceRefresh: Bool,
        refreshInterval: RateRefreshInterval? = nil,
        calendar: Calendar = .current,
        now: Date = Date()
    ) async throws -> RateResolution {
        let previous = cachedRates[account.id] ?? persistedRate
        // The preference controls when to attempt another fetch. Only a
        // successful fetch may replace the last value's validity deadline.
        let candidate = previous
        let refreshIsDue = candidate.map { rate in
            guard let refreshInterval else { return rate.isExpired(at: now) }
            guard let due = refreshInterval.nextRefresh(after: rate.fetchedAt, calendar: calendar) else { return false }
            return due <= now || rate.isExpired(at: now)
        } ?? true
        let needsPipioDisplayRate = candidate.map {
            $0.source == .pipioAccountStatus && ($0.nativeCurrency != .cny || $0.amountMultiplier == nil)
        } ?? false
        if !forceRefresh, !needsPipioDisplayRate,
           let candidate, refreshInterval == .manual || (!refreshIsDue && !pendingRetries.contains(account.id)) {
            cachedRates[account.id] = candidate
            return RateResolution(rate: candidate, isStale: candidate.isExpired(at: now),
                                  refreshFailed: pendingRetries.contains(account.id))
        }

        do {
            let fetched = try await adapter.fetchAccountRate(for: account, credential: credential)
            try Task.checkCancellation()
            let fresh = applying(refreshInterval, to: fetched, calendar: calendar)
            guard fresh.accountID == account.id else { throw ProviderError.missingRate }
            cachedRates[account.id] = fresh
            pendingRetries.remove(account.id)
            return RateResolution(rate: fresh, isStale: false)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let providerError = error as? ProviderError, case .rateLimited = providerError { throw providerError }
            if let candidate, !needsPipioDisplayRate {
                cachedRates[account.id] = candidate
                pendingRetries.insert(account.id)
                return RateResolution(rate: candidate, isStale: candidate.isExpired(at: now), refreshFailed: true)
            }
            throw error
        }
    }

    /// Apply the preference only to newly fetched values, never a fallback.
    private func applying(_ interval: RateRefreshInterval?, to rate: AccountRate, calendar: Calendar) -> AccountRate {
        guard let interval else { return rate }
        return rate.applying(interval, calendar: calendar)
    }

    public func remove(accountID: UUID) {
        cachedRates.removeValue(forKey: accountID)
        pendingRetries.remove(accountID)
    }
}
