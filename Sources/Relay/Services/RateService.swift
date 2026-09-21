import Foundation

public struct RateResolution: Sendable, Equatable {
    public let rate: AccountRate
    public let isStale: Bool
}

/// Account-scoped rate cache. There is intentionally no provider- or host-level
/// cache because two accounts can have different pricing/rate configurations.
public actor RateService {
    private var cachedRates: [UUID: AccountRate] = [:]

    public init() {}

    public func seed(_ rate: AccountRate) {
        cachedRates[rate.accountID] = rate
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
        now: Date = Date()
    ) async throws -> RateResolution {
        let candidate = cachedRates[account.id] ?? persistedRate
        // Older Pipio snapshots omitted the published USD exchange rate. Re-fetch
        // these incomplete rates instead of waiting for the weekly expiry.
        let needsPipioConversion = candidate.map {
            $0.source == .pipioAccountStatus && $0.nativeCurrency == .usd && $0.conversionToCNY == nil &&
            !(account.manualUSDToCNY.map(USDToCNYRate.isValid) ?? false)
        } ?? false
        if !forceRefresh, !needsPipioConversion, let candidate, !candidate.isExpired(at: now) {
            cachedRates[account.id] = candidate
            return RateResolution(rate: candidate, isStale: false)
        }

        do {
            let fresh = try await adapter.fetchAccountRate(for: account, credential: credential)
            guard fresh.accountID == account.id else { throw ProviderError.missingRate }
            cachedRates[account.id] = fresh
            return RateResolution(rate: fresh, isStale: false)
        } catch {
            if let candidate {
                cachedRates[account.id] = candidate
                return RateResolution(rate: candidate, isStale: true)
            }
            throw error
        }
    }

    public func remove(accountID: UUID) {
        cachedRates.removeValue(forKey: accountID)
    }
}
