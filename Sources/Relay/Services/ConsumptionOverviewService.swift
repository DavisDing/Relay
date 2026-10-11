import Foundation

public struct ConsumptionPeriod: Sendable {
    public let amounts: [MoneyValue]
    public let knownDays: Int
    public let expectedDays: Int
    public let unknownDays: Int
    public var isComplete: Bool { expectedDays > 0 && knownDays == expectedDays && unknownDays == 0 && amounts.count == 1 }
}

public struct ConsumptionOverviewRow: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let group: String
    public let today: ConsumptionPeriod
    public let month: ConsumptionPeriod
    public let previousMonth: ConsumptionPeriod
    public let comparableCurrentPeriod: ConsumptionPeriod
    public let comparablePreviousPeriod: ConsumptionPeriod
    public var changePercent: Decimal? {
        guard comparableCurrentPeriod.isComplete, comparablePreviousPeriod.isComplete, comparableCurrentPeriod.expectedDays == comparablePreviousPeriod.expectedDays,
              let current = comparableCurrentPeriod.amounts.first, let previous = comparablePreviousPeriod.amounts.first,
              current.currency == previous.currency, previous.amount > 0 else { return nil }
        return (current.amount - previous.amount) / previous.amount * 100
    }
}

public struct ConsumptionGroup: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let amounts: [MoneyValue]
    public let knownDays: Int
    public let expectedDays: Int
}

public enum ConsumptionOverviewService {
    public static func rows(accounts: [AccountConfiguration], history: [DailyUsageRecord], at now: Date = Date(),
                            calendar: Calendar = .autoupdatingCurrent) -> [ConsumptionOverviewRow] {
        accounts.filter { $0.isEnabled && !$0.isHidden && $0.providerKind != .workbuddy2api }.sorted { $0.displayName < $1.displayName }.compactMap { account in
            let calendar = BudgetService.calendar(for: account.providerKind, fallback: calendar)
            guard let month = calendar.dateInterval(of: .month, for: now),
                  let previousDate = calendar.date(byAdding: .month, value: -1, to: month.start),
                  let previous = calendar.dateInterval(of: .month, for: previousDate),
                  let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return nil }
            let elapsed = calendar.dateComponents([.day], from: month.start, to: tomorrow).day ?? 0
            let previousDays = calendar.dateComponents([.day], from: previous.start, to: previous.end).day ?? 0
            let completedDays = max(0, elapsed - 1)
            let matchedEnd = calendar.date(byAdding: .day, value: min(completedDays, previousDays), to: previous.start) ?? previous.end
            let records = history.filter { $0.accountID == account.id }
            return ConsumptionOverviewRow(id: account.id, name: account.displayName, group: account.groupName ?? "未分组",
                today: period(records, from: calendar.startOfDay(for: now), to: tomorrow, calendar: calendar),
                month: period(records, from: month.start, to: tomorrow, calendar: calendar),
                previousMonth: period(records, from: previous.start, to: previous.end, calendar: calendar),
                comparableCurrentPeriod: period(records, from: month.start, to: calendar.startOfDay(for: now), calendar: calendar),
                comparablePreviousPeriod: period(records, from: previous.start, to: matchedEnd, calendar: calendar))
        }
    }

    public static func groups(_ rows: [ConsumptionOverviewRow], daily: Bool = false) -> [ConsumptionGroup] {
        Dictionary(grouping: rows, by: \.group).map { name, rows in
            let periods = rows.map { daily ? $0.today : $0.month }
            let amounts = sums(periods.flatMap(\.amounts))
            return ConsumptionGroup(name: name, amounts: amounts, knownDays: periods.reduce(0) { $0 + $1.knownDays },
                expectedDays: periods.reduce(0) { $0 + $1.expectedDays })
        }.sorted { $0.name < $1.name }
    }

    private static func period(_ records: [DailyUsageRecord], from start: Date, to end: Date, calendar: Calendar) -> ConsumptionPeriod {
        let selected = records.filter { $0.day >= start && $0.day < end }
        let days = Dictionary(selected.map { (calendar.startOfDay(for: $0.day), $0) }, uniquingKeysWith: { a, b in a.updatedAt > b.updatedAt ? a : b })
        let known = days.values.compactMap(\.spend).filter { !$0.amount.isNaN && $0.amount >= 0 }
        let expected = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return ConsumptionPeriod(amounts: sums(known), knownDays: known.count, expectedDays: expected, unknownDays: max(0, expected - known.count))
    }
    private static func sums(_ amounts: [MoneyValue]) -> [MoneyValue] {
        Currency.allCases.compactMap { currency in
            let values = amounts.filter { $0.currency == currency }
            guard !values.isEmpty else { return nil }
            return MoneyValue(amount: values.reduce(Decimal(0)) { $0 + $1.amount }, currency: currency)
        }
    }
}
