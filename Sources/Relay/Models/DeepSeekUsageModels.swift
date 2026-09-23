import Foundation

/// The result of checking whether the official DeepSeek API can provide
/// historical or model-level usage for Relay.
public enum DeepSeekUsageCoverage: String, Codable, Sendable, Equatable {
    case complete
    case partial
    case unsupported
}

public struct DeepSeekUsageQuery: Sendable, Equatable {
    public let accountID: UUID
    public let siteOrigin: URL
    public let startAt: Date
    public let endAt: Date
    public let calendar: Calendar

    public init(
        accountID: UUID,
        siteOrigin: URL,
        startAt: Date,
        endAt: Date,
        calendar: Calendar = .current
    ) {
        self.accountID = accountID
        self.siteOrigin = siteOrigin
        self.startAt = startAt
        self.endAt = endAt
        self.calendar = calendar
    }
}

/// A day-level usage row. Missing metrics remain nil; nil never means zero.
public struct DeepSeekDailyUsage: Sendable, Equatable, Identifiable {
    public let day: Date
    public let spend: MoneyValue?
    public let tokenCount: Int64?
    public let requestCount: Int64?

    public var id: Date { day }

    public init(
        day: Date,
        spend: MoneyValue? = nil,
        tokenCount: Int64? = nil,
        requestCount: Int64? = nil
    ) {
        self.day = day
        self.spend = spend
        self.tokenCount = tokenCount
        self.requestCount = requestCount
    }
}

/// A model-level usage row. Missing metrics remain nil; nil never means zero.
public struct DeepSeekModelUsage: Sendable, Equatable, Identifiable {
    public let modelName: String
    public let spend: MoneyValue?
    public let tokenCount: Int64?
    public let requestCount: Int64?

    public var id: String { modelName }

    public init(
        modelName: String,
        spend: MoneyValue? = nil,
        tokenCount: Int64? = nil,
        requestCount: Int64? = nil
    ) {
        self.modelName = modelName
        self.spend = spend
        self.tokenCount = tokenCount
        self.requestCount = requestCount
    }
}

public enum DeepSeekUsageUnavailableReason: String, Codable, Sendable, Equatable {
    /// The optional platform session token was not supplied by the user.
    case userTokenNotConfigured
    /// The documented account endpoint exposes balance only. Relay does not
    /// call undocumented dashboard or browser endpoints without user consent.
    case officialAPIHasNoHistoricalOrModelUsageEndpoint
}

public struct DeepSeekUsageReport: Sendable, Equatable {
    public let accountID: UUID
    public let coverage: DeepSeekUsageCoverage
    public let daily: [DeepSeekDailyUsage]?
    public let models: [DeepSeekModelUsage]?
    public let unavailableReason: DeepSeekUsageUnavailableReason?
    public let fetchedAt: Date

    public init(
        accountID: UUID,
        coverage: DeepSeekUsageCoverage,
        daily: [DeepSeekDailyUsage]? = nil,
        models: [DeepSeekModelUsage]? = nil,
        unavailableReason: DeepSeekUsageUnavailableReason? = nil,
        fetchedAt: Date = Date()
    ) {
        self.accountID = accountID
        self.coverage = coverage
        self.daily = daily
        self.models = models
        self.unavailableReason = unavailableReason
        self.fetchedAt = fetchedAt
    }

    public static func unsupported(
        accountID: UUID,
        reason: DeepSeekUsageUnavailableReason = .officialAPIHasNoHistoricalOrModelUsageEndpoint,
        fetchedAt: Date = Date()
    ) -> Self {
        Self(
            accountID: accountID,
            coverage: .unsupported,
            unavailableReason: reason,
            fetchedAt: fetchedAt
        )
    }
}
