import Foundation

/// Uses the gateway's documented /healthz, /status and /v1/stats contracts.
/// /v1/stats is process-lifetime data; RefreshCoordinator converts its monotonic
/// counter into a locally persisted, de-duplicated daily history.
public struct WorkBuddy2APIAdapter: ProviderAdapter {
    public let kind: ProviderKind = .workbuddy2api
    private let client: any HTTPClient

    public init(client: any HTTPClient = URLSessionHTTPClient()) {
        self.client = client
    }

    public func fetchAccountRate(for account: AccountConfiguration, credential: ProviderCredential) async throws -> AccountRate {
        try checkCredential(credential)
        _ = try ProviderURLNormalizer.workbuddyOrigin(from: account.siteOrigin)
        return AccountRate(accountID: account.id, source: .providerNativeCurrency, nativeCurrency: .cny,
                           fetchedAt: Date(), expiresAt: nil)
    }

    public func validateAccount(_ account: AccountConfiguration, credential: ProviderCredential) async throws {
        let origin = try ProviderURLNormalizer.workbuddyOrigin(from: account.siteOrigin)
        // /healthz is 503 when the pool has no healthy accounts. Still validate
        // the service marker and continue to /status so zero-account gateways can
        // be saved and inspected in settings.
        var request = URLRequest(url: origin.appendingPathComponent("healthz"))
        request.timeoutInterval = 20
        let (data, response) = try await client.data(for: request)
        guard (200..<300).contains(response.statusCode) || response.statusCode == 503 else {
            try HTTPResponseValidator.validate(response)
            throw ProviderError.incompatibleResponse
        }
        guard let health = try? JSONDecoder().decode(Health.self, from: data),
              health.service == "workbuddy2api" else { throw ProviderError.wrongService }
        _ = try await status(account: account, credential: credential)
    }

    public func fetchSnapshot(
        for account: AccountConfiguration, credential: ProviderCredential,
        rate: AccountRate, now: Date, calendar: Calendar
    ) async throws -> ProviderSnapshot {
        let result = try await status(account: account, credential: credential)
        // Usage statistics are optional. A failed /v1/stats request must not
        // discard the newer credits already returned by /status.
        let statsResult = try? await stats(account: account, credential: credential)
        var seen = Set<String>()
        let children = try result.accounts.map { item -> ProviderSubAccountSnapshot in
            guard !item.uid.isEmpty, seen.insert(item.uid).inserted else { throw ProviderError.incompatibleResponse }
            let name = item.nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = item.manualDisabled ? item.manualReason : (item.disabled ? item.disabledReason : item.reason)
            return ProviderSubAccountSnapshot(
                parentAccountID: account.id, externalID: item.uid,
                displayName: name?.isEmpty == false ? name! : item.uid,
                availablePoints: item.credits.map { Decimal($0) },
                disabled: item.disabled, manualDisabled: item.manualDisabled,
                cooling: item.cooling, statusMessage: reason,
                fetchedAt: now
            )
        }
        let values = children.compactMap(\.availablePoints)
        let total = !children.isEmpty && values.count == children.count ? values.reduce(Decimal.zero, +) : nil
        var capabilities: ProviderCapabilities = total == nil ? [] : [.creditBalance]
        if statsResult != nil {
            capabilities.insert(.requestCount)
            capabilities.insert(.modelUsage)
        }
        return ProviderSnapshot(
            accountID: account.id, balance: nil, todaySpend: nil, monthSpend: nil,
            requestCount: statsResult?.snapshot.total.requests,
            modelUsages: statsResult?.modelUsages,
            capabilities: capabilities,
            freshness: values.count == children.count ? .fresh : .partial,
            fetchedAt: now, rate: rate,
            creditMetrics: CreditMetrics(available: total), subAccounts: children,
            workBuddyStats: statsResult?.snapshot
        )
    }

    public func performSubAccountAction(
        _ action: ProviderSubAccountAction, for account: AccountConfiguration,
        credential: ProviderCredential, externalID: String
    ) async throws {
        // Only act on an account confirmed by the current authenticated status.
        let result = try await status(account: account, credential: credential)
        guard result.accounts.contains(where: { $0.uid == externalID }) else { throw ProviderError.subAccountNotFound }
        let origin = try ProviderURLNormalizer.workbuddyOrigin(from: account.siteOrigin)
        let suffix: String
        switch action { case .disable: suffix = "disable"; case .enable: suffix = "enable" }
        let url = origin.appendingPathComponent("admin/accounts")
            .appendingPathComponent(externalID, isDirectory: false)
            .appendingPathComponent(suffix)
        var request = try authorizedRequest(url: url, credential: credential)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if case .disable(let reason) = action {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["reason": reason ?? ""])
        }
        let (_, response) = try await client.data(for: request)
        try HTTPResponseValidator.validate(response)
    }

    private func status(account: AccountConfiguration, credential: ProviderCredential) async throws -> Status {
        let origin = try ProviderURLNormalizer.workbuddyOrigin(from: account.siteOrigin)
        let request = try freshRequest(url: origin.appendingPathComponent("status"), credential: credential)
        let (data, response) = try await client.data(for: request)
        try HTTPResponseValidator.validate(response)
        guard let result = try? JSONDecoder().decode(Status.self, from: data),
              !result.accounts.contains(where: { $0.uid.isEmpty }) else { throw ProviderError.incompatibleResponse }
        return result
    }

    private func stats(account: AccountConfiguration, credential: ProviderCredential) async throws -> StatsResult? {
        let origin = try ProviderURLNormalizer.workbuddyOrigin(from: account.siteOrigin)
        let request = try freshRequest(url: origin.appendingPathComponent("v1").appendingPathComponent("stats"), credential: credential)
        let (data, response) = try await client.data(for: request)
        // Older gateways may not expose metrics. Keep the status snapshot usable
        // without destroying the previous persisted stats baseline.
        if response.statusCode == 404 || response.statusCode == 501 { return nil }
        try HTTPResponseValidator.validate(response)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(Stats.self, from: data)
        let total = payload.total
        let statsSnapshot = WorkBuddyStatsSnapshot(
            since: payload.since,
            total: WorkBuddyStatsCounter(
                requests: total.requests, success: total.success, failed: total.failed,
                streaming: total.streaming, promptTokens: total.promptTokens,
                completionTokens: total.completionTokens, totalTokens: total.totalTokens,
                cacheHitTokens: total.cacheHitTokens, cacheMissTokens: total.cacheMissTokens,
                cacheWriteTokens: total.cacheWriteTokens, credit: total.credit
            )
        )
        let modelUsages = payload.models.map { item in
            ModelUsageSummary(
                modelName: item.model,
                tokenCount: item.totalTokens,
                requestCount: item.requests,
                cacheHitRate: item.cacheHitRate,
                spend: MoneyValue(amount: item.credit, currency: .cny)
            )
        }
        return StatsResult(snapshot: statsSnapshot, modelUsages: modelUsages)
    }

    private func checkCredential(_ credential: ProviderCredential) throws {
        guard !credential.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.invalidCredential
        }
    }

    private func authorizedRequest(url: URL, credential: ProviderCredential) throws -> URLRequest {
        try checkCredential(credential)
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credential.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func freshRequest(url: URL, credential: ProviderCredential) throws -> URLRequest {
        var request = try authorizedRequest(url: url, credential: credential)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    private struct StatsResult {
        let snapshot: WorkBuddyStatsSnapshot
        let modelUsages: [ModelUsageSummary]
    }

    private struct Stats: Decodable {
        let since: Date
        let total: Counter
        let models: [Model]
    }

    private struct Counter: Decodable {
        let requests: Int64
        let success: Int64
        let failed: Int64
        let streaming: Int64
        let promptTokens: Int64
        let completionTokens: Int64
        let totalTokens: Int64
        let cacheHitTokens: Int64
        let cacheMissTokens: Int64
        let cacheWriteTokens: Int64
        let credit: Decimal

        enum CodingKeys: String, CodingKey {
            case requests, success, failed, streaming
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
            case cacheHitTokens = "cache_hit_tokens"
            case cacheMissTokens = "cache_miss_tokens"
            case cacheWriteTokens = "cache_write_tokens"
            case credit
        }
    }

    private struct Model: Decodable {
        let model: String
        let requests: Int64
        let totalTokens: Int64
        let cacheHitRate: Decimal?
        let credit: Decimal

        enum CodingKeys: String, CodingKey {
            case model, requests, credit
            case totalTokens = "total_tokens"
            case cacheHitRate = "cache_hit_rate"
        }
    }

    private struct Health: Decodable { let service: String }
    private struct Status: Decodable {
        let accounts: [Entry]
    }
    private struct Entry: Decodable {
        let uid: String
        let nickname: String?
        let credits: Int64?
        let disabled: Bool
        let manualDisabled: Bool
        let cooling: Bool
        let disabledReason: String?
        let manualReason: String?
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case uid, nickname, credits, disabled, cooling, reason
            case manualDisabled = "manual_disabled"
            case disabledReason = "disabled_reason"
            case manualReason = "manual_reason"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uid = try c.decode(String.self, forKey: .uid)
            nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
            credits = try c.decodeIfPresent(Int64.self, forKey: .credits)
            disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
            manualDisabled = try c.decodeIfPresent(Bool.self, forKey: .manualDisabled) ?? false
            cooling = try c.decodeIfPresent(Bool.self, forKey: .cooling) ?? false
            disabledReason = try c.decodeIfPresent(String.self, forKey: .disabledReason)
            manualReason = try c.decodeIfPresent(String.self, forKey: .manualReason)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
        }
    }
}
