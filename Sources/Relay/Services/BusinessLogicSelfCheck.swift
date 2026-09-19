import Foundation

/// Lightweight executable self-check used in environments without XCTest/Xcode.
/// It uses only placeholder values and never emits credentials.
public enum BusinessLogicSelfCheck {
    public static func run() throws {
        let normalized = try ProviderURLNormalizer.pipio(from: URL(string: "https://pipio.io/v1")!)
        precondition(normalized.origin.absoluteString == "https://pipio.io")
        precondition(normalized.managementBaseURL.absoluteString == "https://pipio.io/api")

        let firstID = UUID()
        let secondID = UUID()
        let now = Date()
        let firstRate = AccountRate(accountID: firstID, source: .pipioAccountStatus, nativeCurrency: .usd, quotaPerUnit: 500_000, fetchedAt: now)
        let secondRate = AccountRate(accountID: secondID, source: .pipioAccountStatus, nativeCurrency: .usd, quotaPerUnit: 1_000_000, fetchedAt: now)
        precondition(firstRate.accountID != secondRate.accountID)
        precondition(firstRate.quotaPerUnit != secondRate.quotaPerUnit)

        let deepSeekRate = AccountRate(accountID: UUID(), source: .providerNativeCurrency, nativeCurrency: .cny, conversionToCNY: 1, fetchedAt: now)
        precondition(deepSeekRate.quotaPerUnit == nil)
        precondition(deepSeekRate.nativeCurrency == .cny)

        let cnyID = UUID()
        let usdID = UUID()
        let cnySnapshot = ProviderSnapshot(accountID: cnyID, balance: MoneyValue(amount: 100, currency: .cny), todaySpend: nil, monthSpend: nil, requestCount: nil, capabilities: [.balance], freshness: .fresh, rate: AccountRate(accountID: cnyID, source: .providerNativeCurrency, nativeCurrency: .cny, conversionToCNY: 1, fetchedAt: now))
        let usdSnapshot = ProviderSnapshot(accountID: usdID, balance: MoneyValue(amount: 10, currency: .usd), todaySpend: nil, monthSpend: nil, requestCount: nil, capabilities: [.balance], freshness: .fresh, rate: AccountRate(accountID: usdID, source: .pipioAccountStatus, nativeCurrency: .usd, fetchedAt: now))
        let total = DashboardAggregator.balanceTotal(snapshots: [cnySnapshot, usdSnapshot], targetCurrency: .cny, now: now)
        precondition(total.value?.amount == 100)
        precondition(!total.isComplete)
        precondition(total.excludedAccountIDs.contains(usdID))
    }
}
