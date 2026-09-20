import Foundation

public protocol DeepSeekUsageProviding: Sendable {
    func fetchUsage(
        query: DeepSeekUsageQuery,
        credential: ProviderCredential
    ) async throws -> DeepSeekUsageReport
}

/// Capability probe and future extension point for DeepSeek usage data.
///
/// DeepSeek's documented API exposes account balance at `/user/balance` and
/// per-request token usage in generation responses. Relay only reads the
/// account balance API; it does not issue model requests and must not scrape
/// the web dashboard. Therefore historical and model-level account usage is
/// explicitly reported as unsupported rather than inferred or zero-filled.
public struct DeepSeekUsageService: DeepSeekUsageProviding, Sendable {
    private let client: any HTTPClient

    public init(client: any HTTPClient = URLSessionHTTPClient()) {
        self.client = client
    }

    public func fetchUsage(
        query: DeepSeekUsageQuery,
        credential: ProviderCredential
    ) async throws -> DeepSeekUsageReport {
        try validate(query: query, credential: credential)

        // Keep the injected client in the service contract so a future,
        // officially documented usage endpoint can be added without changing
        // callers. Do not probe guessed or private endpoints today.
        _ = client
        return .unsupported(accountID: query.accountID)
    }

    public func probe() -> DeepSeekUsageCoverage {
        .unsupported
    }

    private func validate(
        query: DeepSeekUsageQuery,
        credential: ProviderCredential
    ) throws {
        guard !credential.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.invalidCredential
        }
        guard query.startAt <= query.endAt else {
            throw DeepSeekUsageServiceError.invalidDateRange
        }
        _ = try ProviderURLNormalizer.secureOrigin(from: query.siteOrigin)
    }
}

public enum DeepSeekUsageServiceError: Error, Sendable, Equatable, LocalizedError {
    case invalidDateRange

    public var errorDescription: String? {
        switch self {
        case .invalidDateRange:
            return "用量查询的开始时间不能晚于结束时间。"
        }
    }
}
