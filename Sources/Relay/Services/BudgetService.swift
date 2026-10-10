import Foundation

public enum BudgetProgress: Sendable, Equatable {
    case disabled
    case unavailable(String)
    case known(spend: MoneyValue, budget: MoneyValue, ratio: Decimal)

    public var ratio: Decimal? {
        if case let .known(_, _, value) = self { return value }
        return nil
    }
}

public enum BudgetThreshold: Int, Codable, Sendable, CaseIterable, Hashable {
    case approaching = 80
    case exceeded = 100
}

/// The month uses the provider's calendar. State is local-only and must never be
/// copied into RelaySyncData, backups, or portable configuration documents.
public struct BudgetAlertKey: Codable, Sendable, Hashable {
    public let accountID: UUID
    public let month: String
    public let currency: Currency
    public let threshold: BudgetThreshold
    public let budgetAmount: String

    public init(accountID: UUID, month: String, currency: Currency, threshold: BudgetThreshold, budgetAmount: Decimal) {
        self.accountID = accountID
        self.month = month
        self.currency = currency
        self.threshold = threshold
        self.budgetAmount = NSDecimalNumber(decimal: budgetAmount).stringValue
    }
}

public struct BudgetAlertState: Codable, Sendable, Equatable {
    public private(set) var delivered: Set<BudgetAlertKey>

    public init(delivered: Set<BudgetAlertKey> = []) { self.delivered = delivered }

    /// Call only after the notification center accepted delivery. A refused or
    /// failed notification remains eligible on the next successful refresh.
    public mutating func markDelivered(_ event: BudgetAlertEvent) {
        delivered.insert(event.key)
        if event.key.threshold == .exceeded {
            delivered.insert(BudgetAlertKey(accountID: event.key.accountID, month: event.key.month,
                                             currency: event.key.currency, threshold: .approaching, budgetAmount: event.budget.amount))
        }
    }

    public mutating func removeAccount(_ id: UUID) { delivered = delivered.filter { $0.accountID != id } }

    public mutating func retain(month: String, accountID: UUID) {
        delivered = delivered.filter { $0.accountID != accountID || $0.month == month }
    }
}

public struct BudgetAlertEvent: Sendable, Equatable {
    public let key: BudgetAlertKey
    public let accountName: String
    public let spend: MoneyValue
    public let budget: MoneyValue
    public let ratio: Decimal

    public var notificationIdentifier: String {
        "relay-budget-\(key.accountID.uuidString)-\(key.month)-\(key.currency.rawValue)-\(key.budgetAmount)-\(key.threshold.rawValue)"
    }

    public var title: String {
        key.threshold == .exceeded ? "月消费已达到预算" : "月消费已达到预算的 80%"
    }

    public var message: String {
        "\(accountName)：本月已消费 \(RelayNumberFormatter.money(spend.amount, currency: spend.currency))，预算 \(RelayNumberFormatter.money(budget.amount, currency: budget.currency))。"
    }
}

public enum BudgetService {
    public static func calendar(for provider: ProviderKind, fallback: Calendar = .current) -> Calendar {
        guard provider == .deepseek else { return fallback }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        return calendar
    }

    public static func monthKey(at date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    public static func progress(
        budget: MoneyValue?, snapshot: ProviderSnapshot?, accountID: UUID,
        now: Date = Date(), calendar: Calendar = .current
    ) -> BudgetProgress {
        guard let budget else { return .disabled }
        guard !budget.amount.isNaN, budget.amount > 0 else {
            return .unavailable("预算必须为大于零的金额")
        }
        guard let snapshot, snapshot.accountID == accountID else {
            return .unavailable("尚无本月消费数据")
        }
        guard monthKey(at: snapshot.fetchedAt, calendar: calendar) == monthKey(at: now, calendar: calendar) else {
            return .unavailable("缓存来自其他月份，请刷新后查看")
        }
        guard let spend = snapshot.monthSpend, !spend.amount.isNaN, spend.amount >= 0 else {
            return .unavailable("服务商未返回可靠的月消费")
        }
        guard spend.currency == budget.currency else {
            return .unavailable("月消费与预算币种不同，请使用 \(spend.currency.rawValue) 预算")
        }
        return .known(spend: spend, budget: budget, ratio: spend.amount / budget.amount)
    }

    /// Returns at most one event. A first observation over 100% sends only the
    /// stronger notification, and marking it delivered covers the 80% threshold.
    public static func nextAlert(
        accountID: UUID, accountName: String, isEnabled: Bool,
        budget: MoneyValue?, snapshot: ProviderSnapshot?, state: BudgetAlertState,
        now: Date = Date(), calendar: Calendar = .current
    ) -> BudgetAlertEvent? {
        guard isEnabled, snapshot?.freshness == .fresh,
              case let .known(spend, budget, ratio) = progress(budget: budget, snapshot: snapshot,
                                                            accountID: accountID, now: now, calendar: calendar) else { return nil }
        let threshold: BudgetThreshold
        if ratio >= 1 { threshold = .exceeded }
        else if ratio >= Decimal(string: "0.8")! { threshold = .approaching }
        else { return nil }
        let key = BudgetAlertKey(accountID: accountID, month: monthKey(at: now, calendar: calendar),
                                 currency: budget.currency, threshold: threshold, budgetAmount: budget.amount)
        guard !state.delivered.contains(key) else { return nil }
        return BudgetAlertEvent(key: key, accountName: accountName, spend: spend, budget: budget, ratio: ratio)
    }

    public static func parseBudget(_ text: String, currency: Currency) throws -> MoneyValue? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              !amount.isNaN, amount > 0 else { throw BudgetInputError.invalidAmount }
        return MoneyValue(amount: amount, currency: currency)
    }
}

public enum BudgetInputError: Error, LocalizedError {
    case invalidAmount
    public var errorDescription: String? { "请输入大于零的完整金额；留空可关闭预算。" }
}
