import Foundation

public enum Currency: String, Codable, CaseIterable, Sendable, Hashable {
    case cny = "CNY"
    case usd = "USD"
    
    public var symbol: String {
        switch self {
        case .cny: return "¥"
        case .usd: return "$"
        }
    }
}

public enum ProviderKind: String, Codable, CaseIterable, Sendable, Hashable {
    case pipio = "Pipio"
    case deepseek = "DeepSeek"
    case custom = "自定义 (OpenAI兼容)"
}

public extension ProviderKind {
    /// Providers with a production adapter in the current release.
    static var supportedCases: [ProviderKind] { [.pipio, .deepseek] }
}

public enum AccountStatus: Sendable, Equatable {
    case ok
    case warning(String)
    case error(String)
    case retrying(seconds: Int)
}

public struct AccountModel: Identifiable, Sendable {
    public let id: String
    public var name: String
    public var kind: ProviderKind
    public var baseURL: String
    public var balance: Decimal?
    public var currency: Currency
    public var todaySpend: Decimal?
    public var monthSpend: Decimal?
    public var status: AccountStatus
    public var lastUpdated: Date?
    public var isEnabled: Bool
    public var lowBalanceThreshold: Decimal?
    public var manualUSDToCNY: Decimal?
    public var quotaPerUnit: Decimal?
    public var siteUSDToCNY: Decimal?
    public var siteRateIsExpired: Bool
    
    public init(id: String = UUID().uuidString,
                name: String,
                kind: ProviderKind,
                baseURL: String,
                balance: Decimal?,
                currency: Currency,
                todaySpend: Decimal? = nil,
                monthSpend: Decimal? = nil,
                status: AccountStatus = .ok,
                lastUpdated: Date? = Date(),
                isEnabled: Bool = true,
                lowBalanceThreshold: Decimal? = nil,
                manualUSDToCNY: Decimal? = nil,
                quotaPerUnit: Decimal? = nil,
                siteUSDToCNY: Decimal? = nil,
                siteRateIsExpired: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.balance = balance
        self.currency = currency
        self.todaySpend = todaySpend
        self.monthSpend = monthSpend
        self.status = status
        self.lastUpdated = lastUpdated
        self.isEnabled = isEnabled
        self.lowBalanceThreshold = lowBalanceThreshold
        self.manualUSDToCNY = manualUSDToCNY
        self.quotaPerUnit = quotaPerUnit
        self.siteUSDToCNY = siteUSDToCNY
        self.siteRateIsExpired = siteRateIsExpired
    }
}

public struct DailySpendPoint: Identifiable, Sendable {
    public let id: String
    public let dateString: String
    public let amount: Decimal
    
    public init(id: String = UUID().uuidString, dateString: String, amount: Decimal) {
        self.id = id
        self.dateString = dateString
        self.amount = amount
    }
}

public struct ModelUsageItem: Identifiable, Sendable {
    public let id: String
    public let modelName: String
    public let tokens: String
    public let tokenCount: Int64?
    public let cost: Decimal?
    public let currency: Currency
    public let percentage: Double?
    public let cacheHitRate: Decimal?
    
    public init(id: String = UUID().uuidString,
                modelName: String,
                tokens: String,
                cost: Decimal?,
                currency: Currency,
                percentage: Double?,
                cacheHitRate: Decimal? = nil,
                tokenCount: Int64? = nil) {
        self.id = id
        self.modelName = modelName
        self.tokens = tokens
        self.tokenCount = tokenCount
        self.cost = cost
        self.currency = currency
        self.percentage = percentage
        self.cacheHitRate = cacheHitRate
    }
}

extension ModelUsageItem {
    static func items(from summaries: [ModelUsageSummary], currency: Currency) -> [ModelUsageItem] {
        let complete = summaries.allSatisfy { $0.spend?.currency == currency }
        let total = summaries.reduce(Decimal.zero) { $0 + ($1.spend?.amount ?? .zero) }
        return summaries.sorted(by: ModelUsageSummary.spendDescending).map { summary in
            let cost = summary.spend?.amount
            return ModelUsageItem(
                id: summary.id, modelName: summary.modelName,
                tokens: summary.tokenCount.map { $0.formatted() } ?? "--",
                cost: cost, currency: summary.spend?.currency ?? currency,
                percentage: complete && total > 0 ? cost.map { NSDecimalNumber(decimal: $0 / total).doubleValue } : nil,
                cacheHitRate: summary.cacheHitRate,
                tokenCount: summary.tokenCount
            )
        }
    }
}

public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case followSystem = "跟随系统"
    case light = "浅色磨砂"
    case dark = "深色磨砂"
}
