import Foundation

public struct AccountConfiguration: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var displayName: String
    public var providerKind: ProviderKind
    public var siteOrigin: URL
    public var credentialReference: String
    public var isEnabled: Bool
    /// Keeps an account connected and refreshing while excluding it from the home dashboard.
    public var isHidden: Bool
    public var lowBalanceThreshold: Decimal?
    /// User override for USD → CNY only; never used to normalize provider quota.
    public var manualUSDToCNY: Decimal?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, displayName, providerKind, siteOrigin, credentialReference, isEnabled, isHidden
        case lowBalanceThreshold, manualUSDToCNY, sortOrder, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        providerKind = try container.decode(ProviderKind.self, forKey: .providerKind)
        siteOrigin = try container.decode(URL.self, forKey: .siteOrigin)
        credentialReference = try container.decode(String.self, forKey: .credentialReference)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        lowBalanceThreshold = try container.decodeIfPresent(Decimal.self, forKey: .lowBalanceThreshold)
        manualUSDToCNY = try container.decodeIfPresent(Decimal.self, forKey: .manualUSDToCNY)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    public init(
        id: UUID = UUID(),
        displayName: String,
        providerKind: ProviderKind,
        siteOrigin: URL,
        credentialReference: String? = nil,
        isEnabled: Bool = true,
        isHidden: Bool = false,
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
        self.isHidden = isHidden
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

/// Explicit optional-string edit semantics. `set(nil)` means clear the saved value.
public enum OptionalStringUpdate: Sendable {
    case unchanged
    case set(String?)
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
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let secret: String
    public let pipioUserID: String?
    /// Optional DeepSeek platform session token used only for platform usage APIs.
    /// It is never exported in RelaySyncData because credentials live separately.
    public let deepSeekUserToken: String?

    public init(
        secret: String,
        pipioUserID: String? = nil,
        deepSeekUserToken: String? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.secret = secret
        self.pipioUserID = pipioUserID
        self.deepSeekUserToken = deepSeekUserToken
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
    public static let creditBalance = Self(rawValue: 1 << 5)
}

public enum DataFreshness: String, Codable, Sendable {
    case fresh
    case stale
    case partial
}

public struct WorkBuddyStatsCounter: Codable, Sendable, Equatable {
    public let requests: Int64
    public let success: Int64
    public let failed: Int64
    public let streaming: Int64
    public let promptTokens: Int64
    public let completionTokens: Int64
    public let totalTokens: Int64
    public let cacheHitTokens: Int64
    public let cacheMissTokens: Int64
    public let cacheWriteTokens: Int64
    public let credit: Decimal

    public init(
        requests: Int64 = 0,
        success: Int64 = 0,
        failed: Int64 = 0,
        streaming: Int64 = 0,
        promptTokens: Int64 = 0,
        completionTokens: Int64 = 0,
        totalTokens: Int64 = 0,
        cacheHitTokens: Int64 = 0,
        cacheMissTokens: Int64 = 0,
        cacheWriteTokens: Int64 = 0,
        credit: Decimal = .zero
    ) {
        self.requests = requests
        self.success = success
        self.failed = failed
        self.streaming = streaming
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cacheHitTokens = cacheHitTokens
        self.cacheMissTokens = cacheMissTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.credit = credit
    }

    private enum CodingKeys: String, CodingKey {
        case requests, success, failed, streaming
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case cacheHitTokens = "cache_hit_tokens"
        case cacheMissTokens = "cache_miss_tokens"
        case cacheWriteTokens = "cache_write_tokens"
        case credit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requests = try c.decodeIfPresent(Int64.self, forKey: .requests) ?? 0
        success = try c.decodeIfPresent(Int64.self, forKey: .success) ?? 0
        failed = try c.decodeIfPresent(Int64.self, forKey: .failed) ?? 0
        streaming = try c.decodeIfPresent(Int64.self, forKey: .streaming) ?? 0
        promptTokens = try c.decodeIfPresent(Int64.self, forKey: .promptTokens) ?? 0
        completionTokens = try c.decodeIfPresent(Int64.self, forKey: .completionTokens) ?? 0
        totalTokens = try c.decodeIfPresent(Int64.self, forKey: .totalTokens) ?? 0
        cacheHitTokens = try c.decodeIfPresent(Int64.self, forKey: .cacheHitTokens) ?? 0
        cacheMissTokens = try c.decodeIfPresent(Int64.self, forKey: .cacheMissTokens) ?? 0
        cacheWriteTokens = try c.decodeIfPresent(Int64.self, forKey: .cacheWriteTokens) ?? 0
        credit = try c.decodeIfPresent(Decimal.self, forKey: .credit) ?? .zero
    }
}

public struct WorkBuddyStatsSnapshot: Codable, Sendable, Equatable {
    public let since: Date
    public let total: WorkBuddyStatsCounter

    public init(since: Date, total: WorkBuddyStatsCounter) {
        self.since = since
        self.total = total
    }
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

public struct CreditMetrics: Codable, Sendable, Equatable {
    public let available: Decimal?
    public let consumedToday: Decimal?
    public let earnedToday: Decimal?

    public init(available: Decimal?, consumedToday: Decimal? = nil, earnedToday: Decimal? = nil) {
        self.available = available
        self.consumedToday = consumedToday
        self.earnedToday = earnedToday
    }
}

public struct ProviderSubAccountSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let parentAccountID: UUID
    public let externalID: String
    public let displayName: String
    public let availablePoints: Decimal?
    public let disabled: Bool
    public let manualDisabled: Bool
    public let cooling: Bool
    public let statusMessage: String?
    public let fetchedAt: Date

    public init(
        parentAccountID: UUID,
        externalID: String,
        displayName: String,
        availablePoints: Decimal?,
        disabled: Bool = false,
        manualDisabled: Bool = false,
        cooling: Bool = false,
        statusMessage: String? = nil,
        fetchedAt: Date = Date()
    ) {
        self.parentAccountID = parentAccountID
        self.externalID = externalID
        self.id = "\(parentAccountID.uuidString):\(externalID)"
        self.displayName = displayName
        self.availablePoints = availablePoints
        self.disabled = disabled
        self.manualDisabled = manualDisabled
        self.cooling = cooling
        self.statusMessage = statusMessage
        self.fetchedAt = fetchedAt
    }
}

public enum ProviderSubAccountAction: Sendable, Equatable {
    case disable(reason: String?)
    case enable
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
    public let creditMetrics: CreditMetrics?
    public let subAccounts: [ProviderSubAccountSnapshot]?
    /// Process-lifetime workbuddy2api statistics used as the deduplication baseline.
    public let workBuddyStats: WorkBuddyStatsSnapshot?

    private enum CodingKeys: String, CodingKey {
        case accountID, balance, todaySpend, monthSpend, requestCount, modelUsages
        case capabilities, freshness, fetchedAt, rate, creditMetrics, subAccounts, workBuddyStats
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try c.decode(UUID.self, forKey: .accountID)
        balance = try c.decodeIfPresent(MoneyValue.self, forKey: .balance)
        todaySpend = try c.decodeIfPresent(MoneyValue.self, forKey: .todaySpend)
        monthSpend = try c.decodeIfPresent(MoneyValue.self, forKey: .monthSpend)
        requestCount = try c.decodeIfPresent(Int64.self, forKey: .requestCount)
        modelUsages = try c.decodeIfPresent([ModelUsageSummary].self, forKey: .modelUsages)
        capabilities = try c.decode(ProviderCapabilities.self, forKey: .capabilities)
        freshness = try c.decode(DataFreshness.self, forKey: .freshness)
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        rate = try c.decode(AccountRate.self, forKey: .rate)
        creditMetrics = try c.decodeIfPresent(CreditMetrics.self, forKey: .creditMetrics)
        subAccounts = try c.decodeIfPresent([ProviderSubAccountSnapshot].self, forKey: .subAccounts)
        workBuddyStats = try c.decodeIfPresent(WorkBuddyStatsSnapshot.self, forKey: .workBuddyStats)
    }

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
        rate: AccountRate,
        creditMetrics: CreditMetrics? = nil,
        subAccounts: [ProviderSubAccountSnapshot]? = nil,
        workBuddyStats: WorkBuddyStatsSnapshot? = nil
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
        self.creditMetrics = creditMetrics
        self.subAccounts = subAccounts
        self.workBuddyStats = workBuddyStats
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

public struct CreditDashboardTotal: Sendable, Equatable {
    public let value: Decimal?
    public let isComplete: Bool
    public let excludedAccountIDs: Set<UUID>

    public init(value: Decimal?, isComplete: Bool, excludedAccountIDs: Set<UUID> = []) {
        self.value = value
        self.isComplete = isComplete
        self.excludedAccountIDs = excludedAccountIDs
    }
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
    case oneMonth
    case halfYear
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
