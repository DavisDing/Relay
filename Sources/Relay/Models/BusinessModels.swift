import Foundation

public struct AccountConfiguration: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var displayName: String
    public var providerKind: ProviderKind
    public var siteOrigin: URL
    public var credentialReference: String
    public var isEnabled: Bool
    public var lowBalanceThreshold: Decimal?
    /// User override for USD → CNY only; never used to normalize provider quota.
    public var manualUSDToCNY: Decimal?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        providerKind: ProviderKind,
        siteOrigin: URL,
        credentialReference: String? = nil,
        isEnabled: Bool = true,
        lowBalanceThreshold: Decimal? = Decimal(20),
        manualUSDToCNY: Decimal? = nil,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.providerKind = providerKind
        self.siteOrigin = siteOrigin
        self.credentialReference = credentialReference ?? id.uuidString
        self.isEnabled = isEnabled
        self.lowBalanceThreshold = lowBalanceThreshold
        self.manualUSDToCNY = manualUSDToCNY
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Explicit change semantics keep unrelated edits from clearing a saved override.
public enum ManualExchangeRateUpdate: Sendable {
    case unchanged
    case set(Decimal?)
}

public enum USDToCNYRate {
    public static func isValid(_ value: Decimal) -> Bool {
        !value.isNaN && value > 0
    }

    /// Blank restores automatic mode. Reject partial numbers (e.g. "7.3abc")
    /// rather than relying on Decimal's permissive prefix parsing.
    public static func parseOverride(_ text: String) throws -> Decimal? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              isValid(value) else { throw AccountServiceError.invalidExchangeRate }
        return value
    }
}

public struct ProviderCredential: Codable, Sendable, Equatable, CustomStringConvertible {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let secret: String
    public let pipioUserID: String?

    public init(secret: String, pipioUserID: String? = nil) {
        self.schemaVersion = Self.currentSchemaVersion
        self.secret = secret
        self.pipioUserID = pipioUserID
    }

    public var description: String { "ProviderCredential(<redacted>)" }
}

public struct MoneyValue: Codable, Sendable, Equatable {
    public let amount: Decimal
    public let currency: Currency

    public init(amount: Decimal, currency: Currency) {
        self.amount = amount
        self.currency = currency
    }
}

public enum RateSource: String, Codable, Sendable {
    case pipioAccountStatus
    case providerNativeCurrency
}

/// Every record belongs to exactly one account. It must never be shared merely
/// because two accounts use the same provider or origin.
public struct AccountRate: Codable, Sendable, Equatable {
    public let accountID: UUID
    public let source: RateSource
    public let nativeCurrency: Currency
    public let quotaPerUnit: Decimal?
    public let conversionToCNY: Decimal?
    public let fetchedAt: Date
    public let expiresAt: Date?

    public init(
        accountID: UUID,
        source: RateSource,
        nativeCurrency: Currency,
        quotaPerUnit: Decimal? = nil,
        conversionToCNY: Decimal? = nil,
        fetchedAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.accountID = accountID
        self.source = source
        self.nativeCurrency = nativeCurrency
        self.quotaPerUnit = quotaPerUnit
        self.conversionToCNY = conversionToCNY
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }
}

public struct ProviderCapabilities: OptionSet, Codable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let balance = Self(rawValue: 1 << 0)
    public static let todayUsage = Self(rawValue: 1 << 1)
    public static let monthlyUsage = Self(rawValue: 1 << 2)
    public static let requestCount = Self(rawValue: 1 << 3)
    public static let modelUsage = Self(rawValue: 1 << 4)
}

public enum DataFreshness: String, Codable, Sendable {
    case fresh
    case stale
    case partial
}

public struct ModelUsageSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let modelName: String
    public let tokenCount: Int64?
    public let requestCount: Int64?
    public let cacheHitRate: Decimal?
    public let spend: MoneyValue?

    public init(
        modelName: String,
        tokenCount: Int64?,
        requestCount: Int64?,
        cacheHitRate: Decimal? = nil,
        spend: MoneyValue?
    ) {
        self.id = modelName
        self.modelName = modelName
        self.tokenCount = tokenCount
        self.requestCount = requestCount
        self.cacheHitRate = cacheHitRate
        self.spend = spend
    }
}

extension ModelUsageSummary {
    /// Known spends first (including free models), then unknown; stable ties by name.
    static func spendDescending(_ lhs: ModelUsageSummary, _ rhs: ModelUsageSummary) -> Bool {
        switch (lhs.spend?.amount, rhs.spend?.amount) {
        case let (left?, right?) where left != right: return left > right
        case (_?, nil): return true
        case (nil, _?): return false
        default: return lhs.modelName < rhs.modelName
        }
    }
}

public struct ProviderSnapshot: Codable, Sendable, Equatable {
    public let accountID: UUID
    public let balance: MoneyValue?
    public let todaySpend: MoneyValue?
    public let monthSpend: MoneyValue?
    public let requestCount: Int64?
    public let modelUsages: [ModelUsageSummary]?
    public let capabilities: ProviderCapabilities
    public let freshness: DataFreshness
    public let fetchedAt: Date
    public let rate: AccountRate

    public init(
        accountID: UUID,
        balance: MoneyValue?,
        todaySpend: MoneyValue?,
        monthSpend: MoneyValue?,
        requestCount: Int64?,
        modelUsages: [ModelUsageSummary]? = nil,
        capabilities: ProviderCapabilities,
        freshness: DataFreshness,
        fetchedAt: Date = Date(),
        rate: AccountRate
    ) {
        self.accountID = accountID
        self.balance = balance
        self.todaySpend = todaySpend
        self.monthSpend = monthSpend
        self.requestCount = requestCount
        self.modelUsages = modelUsages
        self.capabilities = capabilities
        self.freshness = freshness
        self.fetchedAt = fetchedAt
        self.rate = rate
    }
}

public extension ProviderSnapshot {
    func todaySpend(on date: Date, calendar: Calendar) -> MoneyValue? {
        calendar.isDate(fetchedAt, inSameDayAs: date) ? todaySpend : nil
    }
}

public struct DashboardTotal: Sendable, Equatable {
    public let value: MoneyValue?
    public let isComplete: Bool
    public let excludedAccountIDs: Set<UUID>
}

public enum RateRefreshInterval: String, Codable, CaseIterable, Sendable {
    case daily
    case weekly
    case monthly
    case manual

    public func nextRefresh(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .daily: return calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly: return calendar.date(byAdding: .day, value: 7, to: date)
        case .monthly: return calendar.date(byAdding: .month, value: 1, to: date)
        case .manual: return nil
        }
    }
}

public enum HistoryRetention: String, Codable, CaseIterable, Sendable {
    case oneYear
    case forever
}

public struct RelaySettings: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var refreshIntervalSeconds: Int
    public var showTodayInMenuBar: Bool
    public var baseCurrency: Currency
    public var defaultLowBalanceThreshold: Decimal
    public var historyRetention: HistoryRetention
    public var iCloudFileSyncEnabled: Bool

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        refreshIntervalSeconds: Int = 300,
        showTodayInMenuBar: Bool = true,
        baseCurrency: Currency = .cny,
        defaultLowBalanceThreshold: Decimal = 20,
        historyRetention: HistoryRetention = .oneYear,
        iCloudFileSyncEnabled: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.refreshIntervalSeconds = max(60, refreshIntervalSeconds)
        self.showTodayInMenuBar = showTodayInMenuBar
        self.baseCurrency = baseCurrency
        self.defaultLowBalanceThreshold = max(0, defaultLowBalanceThreshold)
        self.historyRetention = historyRetention
        self.iCloudFileSyncEnabled = iCloudFileSyncEnabled
    }
}

public struct DailyUsageRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let accountID: UUID
    public let day: Date
    public let spend: MoneyValue?
    public let updatedAt: Date

    public init(accountID: UUID, day: Date, spend: MoneyValue?, updatedAt: Date = Date()) {
        self.id = "\(accountID.uuidString)-\(Int(day.timeIntervalSince1970))"
        self.accountID = accountID
        self.day = day
        self.spend = spend
        self.updatedAt = updatedAt
    }
}

public struct RelaySyncData: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let exportedAt: Date
    public let accounts: [AccountConfiguration]
    public let snapshots: [ProviderSnapshot]
    public let dailyUsage: [DailyUsageRecord]
    public let settingsUpdatedAt: Date?
    public let settings: RelaySettings
    public let deletedAccountIDs: [UUID: Date]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        exportedAt: Date = Date(),
        accounts: [AccountConfiguration],
        snapshots: [ProviderSnapshot],
        dailyUsage: [DailyUsageRecord],
        settings: RelaySettings,
        settingsUpdatedAt: Date? = nil,
        deletedAccountIDs: [UUID: Date] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.accounts = accounts
        self.snapshots = snapshots
        self.dailyUsage = dailyUsage
        self.settingsUpdatedAt = settingsUpdatedAt
        self.settings = settings
        self.deletedAccountIDs = deletedAccountIDs
    }
}
