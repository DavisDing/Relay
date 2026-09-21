import Foundation

public enum DashboardAggregator {
    public static func balanceTotal(
        snapshots: [ProviderSnapshot],
        targetCurrency: Currency,
        now: Date = Date(),
        expectedAccountIDs: Set<UUID>? = nil,
        manualUSDToCNY: [UUID: Decimal] = [:]
    ) -> DashboardTotal {
        aggregate(
            snapshots: snapshots,
            targetCurrency: targetCurrency,
            now: now,
            expectedAccountIDs: expectedAccountIDs,
            manualUSDToCNY: manualUSDToCNY,
            value: { $0.balance }
        )
    }

    public static func todaySpendTotal(
        snapshots: [ProviderSnapshot],
        targetCurrency: Currency,
        now: Date = Date(),
        expectedAccountIDs: Set<UUID>? = nil,
        calendar: Calendar = .current,
        manualUSDToCNY: [UUID: Decimal] = [:]
    ) -> DashboardTotal {
        aggregate(
            snapshots: snapshots,
            targetCurrency: targetCurrency,
            now: now,
            expectedAccountIDs: expectedAccountIDs,
            manualUSDToCNY: manualUSDToCNY,
            value: { $0.todaySpend(on: now, calendar: calendar) }
        )
    }

    private static func aggregate(
        snapshots: [ProviderSnapshot],
        targetCurrency: Currency,
        now: Date,
        expectedAccountIDs: Set<UUID>?,
        manualUSDToCNY: [UUID: Decimal],
        value: (ProviderSnapshot) -> MoneyValue?
    ) -> DashboardTotal {
        let expected = expectedAccountIDs ?? Set(snapshots.map(\.accountID))
        guard !expected.isEmpty else {
            return DashboardTotal(value: nil, isComplete: false, excludedAccountIDs: [])
        }
        var total = Decimal.zero
        var included = false
        var excluded = expected.subtracting(snapshots.map(\.accountID))

        for snapshot in snapshots where expected.contains(snapshot.accountID) {
            guard let money = value(snapshot),
                  let converted = convert(money, using: snapshot.rate, target: targetCurrency, now: now, manualUSDToCNY: manualUSDToCNY[snapshot.accountID]) else {
                excluded.insert(snapshot.accountID)
                continue
            }
            total += converted
            included = true
        }

        return DashboardTotal(
            value: included ? MoneyValue(amount: total, currency: targetCurrency) : nil,
            isComplete: excluded.isEmpty,
            excludedAccountIDs: excluded
        )
    }

    private static func convert(
        _ money: MoneyValue,
        using rate: AccountRate,
        target: Currency,
        now: Date,
        manualUSDToCNY: Decimal?
    ) -> Decimal? {
        if money.currency == target { return money.amount }
        // The snapshot's amounts are already in native currency. A user-set FX
        // rate has no provider expiry and must not alter quota normalization.
        if money.currency == .usd, target == .cny,
           let manualUSDToCNY, USDToCNYRate.isValid(manualUSDToCNY) {
            return money.amount * manualUSDToCNY
        }
        guard !rate.isExpired(at: now), rate.nativeCurrency == money.currency else { return nil }

        switch (money.currency, target) {
        case (.usd, .cny):
            guard let multiplier = rate.conversionToCNY, USDToCNYRate.isValid(multiplier) else { return nil }
            return money.amount * multiplier
        case (.cny, .usd):
            return nil
        default:
            return nil
        }
    }
}

