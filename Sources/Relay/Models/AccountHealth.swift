import Foundation

/// Runtime-only operational state. It is deliberately not Codable or synced.
public enum RefreshSource: Sendable {
    case scheduled, manualAll, manualAccount
    var priority: Int { self == .manualAccount ? 2 : (self == .manualAll ? 1 : 0) }
}

public enum AccountHealthIssue: String, Sendable, Equatable {
    case credentials, permission, rateLimit, network, provider, incompatibleResponse, storage

    public var guidance: String {
        switch self {
        case .credentials: return "请检查或重新录入凭据"
        case .permission: return "请检查凭据的访问权限"
        case .rateLimit: return "服务商限流，等待后重试"
        case .network: return "请检查网络连接"
        case .provider: return "服务商暂时不可用"
        case .incompatibleResponse: return "接口响应变化，请检查适配版本"
        case .storage: return "本地保存失败，请检查存储后重试"
        }
    }

    public init(error: ProviderError) {
        switch error {
        case .invalidCredential, .missingPipioUserID, .invalidPipioUserID, .unauthorized: self = .credentials
        case .forbidden: self = .permission
        case .rateLimited: self = .rateLimit
        case .transport: self = .network
        case .incompatibleResponse, .missingRate, .wrongService: self = .incompatibleResponse
        case .storageUnavailable: self = .storage
        default: self = .provider
        }
    }
}

public enum AccountRefreshPhase: Sendable, Equatable {
    case idle, queued, refreshing, backingOff(until: Date)
    public var isActive: Bool { self != .idle }
}

public struct AccountHealth: Sendable, Equatable {
    public var phase: AccountRefreshPhase = .idle
    public var lastSuccessAt: Date?
    public var issue: AccountHealthIssue?
    public var consecutiveFailures = 0
    public var retryAt: Date?
    public var freshness: DataFreshness?

    public init() {}

    public var summary: String {
        switch phase {
        case .queued: return "等待刷新"
        case .refreshing: return "正在刷新"
        case .backingOff: return issue == .rateLimit ? "限流等待中" : "等待重试"
        case .idle:
            if let issue { return issue.guidance }
            switch freshness {
            case .stale: return "使用上次成功数据"
            case .partial: return "部分指标不可用"
            default: return lastSuccessAt == nil ? "尚未刷新" : "最近刷新成功"
            }
        }
    }

    public var detail: String {
        var parts = [summary]
        if let lastSuccessAt { parts.append("最近成功：" + lastSuccessAt.formatted(date: .abbreviated, time: .standard)) }
        if consecutiveFailures > 0 { parts.append("连续失败 \(consecutiveFailures) 次") }
        if let retryAt { parts.append("可重试时间：" + retryAt.formatted(date: .omitted, time: .standard)) }
        return parts.joined(separator: "；")
    }
}
