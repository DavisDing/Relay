import Foundation

public struct PipioAdapter: ProviderAdapter {
    public let kind: ProviderKind = .pipio
    private let client: any HTTPClient
    private let rateRefreshInterval: RateRefreshInterval

    public init(client: any HTTPClient = URLSessionHTTPClient(), rateRefreshInterval: RateRefreshInterval = .weekly) {
        self.client = client
        self.rateRefreshInterval = rateRefreshInterval
    }

    public func fetchAccountRate(for account: AccountConfiguration, credential: ProviderCredential) async throws -> AccountRate {
        try validateCredential(credential)
        let urls = try ProviderURLNormalizer.pipio(from: account.siteOrigin)
        let url = urls.managementBaseURL.appendingPathComponent("status")
        let (data, response) = try await client.data(for: URLRequest(url: url))
        try HTTPResponseValidator.validate(response)

        let envelope: PipioEnvelope<PipioStatusData> = try decode(data)
        guard envelope.success != false,
              let quotaPerUnit = envelope.data?.quotaPerUnit,
              quotaPerUnit > 0,
              let currency = Currency(providerCode: envelope.data?.creditCurrency ?? envelope.data?.quotaDisplayType) else {
            throw ProviderError.missingRate
        }

        let fetchedAt = Date()
        return AccountRate(
            accountID: account.id,
            source: .pipioAccountStatus,
            nativeCurrency: currency,
            quotaPerUnit: quotaPerUnit,
            conversionToCNY: currency == .cny ? 1 : nil,
            fetchedAt: fetchedAt,
            expiresAt: rateRefreshInterval.nextRefresh(after: fetchedAt)
        )
    }

    public func validateAccount(_ account: AccountConfiguration, credential: ProviderCredential) async throws {
        try validateCredential(credential)
        let urls = try ProviderURLNormalizer.pipio(from: account.siteOrigin)
        let request = try authorizedRequest(
            url: urls.managementBaseURL.appendingPathComponent("user/self"),
            credential: credential
        )
        let (data, response) = try await client.data(for: request)
        try HTTPResponseValidator.validate(response)
        let envelope: PipioEnvelope<PipioUserData> = try decode(data)
        guard envelope.success != false, envelope.data != nil else {
            throw ProviderError.incompatibleResponse
        }
    }

    public func fetchSnapshot(
        for account: AccountConfiguration,
        credential: ProviderCredential,
        rate: AccountRate,
        now: Date,
        calendar: Calendar
    ) async throws -> ProviderSnapshot {
        try validateCredential(credential)
        guard rate.accountID == account.id,
              rate.source == .pipioAccountStatus,
              let quotaPerUnit = rate.quotaPerUnit,
              quotaPerUnit > 0 else {
            throw ProviderError.missingRate
        }

        let urls = try ProviderURLNormalizer.pipio(from: account.siteOrigin)
        let current = try await fetchUser(urls: urls, credential: credential)

        let dayStart = calendar.startOfDay(for: now)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? dayStart

        async let todayResult = fetchStat(
            urls: urls,
            credential: credential,
            range: DateInterval(start: dayStart, end: now)
        )
        async let monthResult = fetchStat(
            urls: urls,
            credential: credential,
            range: DateInterval(start: monthStart, end: now)
        )
        async let modelResult = fetchModelUsages(
            urls: urls,
            credential: credential,
            range: DateInterval(start: dayStart, end: now),
            quotaPerUnit: quotaPerUnit,
            currency: rate.nativeCurrency
        )

        let today = try? await todayResult
        let month = try? await monthResult
        let modelUsages = try? await modelResult
        let currency = rate.nativeCurrency
        let balance = current.quota.map { MoneyValue(amount: $0 / quotaPerUnit, currency: currency) }
        let todaySpend = today?.quota.map { MoneyValue(amount: $0 / quotaPerUnit, currency: currency) }
        let monthSpend = month?.quota.map { MoneyValue(amount: $0 / quotaPerUnit, currency: currency) }

        var capabilities: ProviderCapabilities = []
        if balance != nil { capabilities.insert(.balance) }
        if todaySpend != nil { capabilities.insert(.todayUsage) }
        if monthSpend != nil { capabilities.insert(.monthlyUsage) }
        if current.requestCount != nil { capabilities.insert(.requestCount) }
        if let modelUsages, !modelUsages.isEmpty { capabilities.insert(.modelUsage) }

        guard balance != nil else { throw ProviderError.incompatibleResponse }
        return ProviderSnapshot(
            accountID: account.id,
            balance: balance,
            todaySpend: todaySpend,
            monthSpend: monthSpend,
            requestCount: current.requestCount,
            modelUsages: modelUsages,
            capabilities: capabilities,
            freshness: (today != nil && month != nil) ? .fresh : .partial,
            fetchedAt: now,
            rate: rate
        )
    }

    public func fetchDailyUsage(
        for account: AccountConfiguration,
        credential: ProviderCredential,
        rate: AccountRate,
        endingAt now: Date,
        days: Int,
        calendar: Calendar
    ) async throws -> [DailyUsageRecord] {
        try validateCredential(credential)
        guard rate.accountID == account.id,
              let quotaPerUnit = rate.quotaPerUnit,
              quotaPerUnit > 0 else { throw ProviderError.missingRate }

        let urls = try ProviderURLNormalizer.pipio(from: account.siteOrigin)
        let count = max(1, min(days, 30))
        let today = calendar.startOfDay(for: now)
        var records: [DailyUsageRecord] = []

        // `/api/log/self/stat` accepts an arbitrary timestamp range. Query each
        // calendar day so the chart can be populated immediately, then keep the
        // returned daily aggregates locally for future offline viewing.
        for offset in 0..<count {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            let end = min(nextDay, now)
            guard end > day else { continue }
            guard let stat = try? await fetchStat(
                urls: urls,
                credential: credential,
                range: DateInterval(start: day, end: end)
            ), let quota = stat.quota else { continue }
            records.append(DailyUsageRecord(
                accountID: account.id,
                day: day,
                spend: MoneyValue(amount: quota / quotaPerUnit, currency: rate.nativeCurrency),
                updatedAt: now
            ))
        }
        return records
    }

    private func validateCredential(_ credential: ProviderCredential) throws {
        guard !credential.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.invalidCredential
        }
        guard let rawUserID = credential.pipioUserID,
              !rawUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.missingPipioUserID
        }
        guard let value = Int64(rawUserID), value > 0 else {
            throw ProviderError.invalidPipioUserID
        }
    }

    private func authorizedRequest(url: URL, credential: ProviderCredential) throws -> URLRequest {
        try validateCredential(credential)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credential.secret)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.pipioUserID, forHTTPHeaderField: "Pipio-User")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func fetchUser(urls: NormalizedProviderURLs, credential: ProviderCredential) async throws -> PipioUserData {
        let request = try authorizedRequest(
            url: urls.managementBaseURL.appendingPathComponent("user/self"),
            credential: credential
        )
        let (data, response) = try await client.data(for: request)
        try HTTPResponseValidator.validate(response)
        let envelope: PipioEnvelope<PipioUserData> = try decode(data)
        guard envelope.success != false, let value = envelope.data else {
            throw ProviderError.incompatibleResponse
        }
        return value
    }

    private func fetchStat(
        urls: NormalizedProviderURLs,
        credential: ProviderCredential,
        range: DateInterval
    ) async throws -> PipioStatData {
        var components = URLComponents(
            url: urls.managementBaseURL.appendingPathComponent("log/self/stat"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "start_timestamp", value: String(Int64(range.start.timeIntervalSince1970))),
            URLQueryItem(name: "end_timestamp", value: String(Int64(range.end.timeIntervalSince1970)))
        ]
        guard let url = components?.url else { throw ProviderError.invalidBaseURL }
        let request = try authorizedRequest(url: url, credential: credential)
        let (data, response) = try await client.data(for: request)
        try HTTPResponseValidator.validate(response)
        let envelope: PipioEnvelope<PipioStatData> = try decode(data)
        guard envelope.success != false, let value = envelope.data else {
            throw ProviderError.incompatibleResponse
        }
        return value
    }

    private func fetchModelUsages(
        urls: NormalizedProviderURLs,
        credential: ProviderCredential,
        range: DateInterval,
        quotaPerUnit: Decimal,
        currency: Currency
    ) async throws -> [ModelUsageSummary] {
        struct Aggregate {
            var tokenCount: Int64 = 0
            var hasTokenCount = false
            var promptTokenCount: Int64 = 0
            var hasPromptTokenCount = false
            var cacheReadTokenCount: Int64 = 0
            var hasCacheReadTokenCount = false
            var directCacheHitRateTotal: Decimal = .zero
            var directCacheHitRateWeight: Decimal = .zero
            var hasDirectCacheHitRate = false
            var requestCount: Int64 = 0
            var quota: Decimal = .zero
            var hasQuota = false
        }

        var aggregates: [String: Aggregate] = [:]
        var page = 1
        var expectedTotal: Int64?
        var received = 0

        while page <= 10 {
            var components = URLComponents(
                url: urls.managementBaseURL.appendingPathComponent("log/self"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "start_timestamp", value: String(Int64(range.start.timeIntervalSince1970))),
                URLQueryItem(name: "end_timestamp", value: String(Int64(range.end.timeIntervalSince1970))),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page_size", value: "100")
            ]
            guard let url = components?.url else { throw ProviderError.invalidBaseURL }
            let request = try authorizedRequest(url: url, credential: credential)
            let (data, response) = try await client.data(for: request)
            try HTTPResponseValidator.validate(response)
            let pageData = try parseLogPage(data)
            expectedTotal = pageData.total ?? expectedTotal
            if pageData.items.isEmpty { break }

            for item in pageData.items {
                guard let model = stringValue(item["model_name"] ?? item["modelName"]), !model.isEmpty else { continue }
                var aggregate = aggregates[model] ?? Aggregate()
                aggregate.requestCount += 1
                let prompt = int64Value(item["prompt_tokens"] ?? item["promptTokens"])
                let completion = int64Value(item["completion_tokens"] ?? item["completionTokens"])
                let cacheRead = int64Value(
                    item["cache_read_input_tokens"] ??
                    item["cacheReadInputTokens"] ??
                    item["cache_read_tokens"] ??
                    item["cacheReadTokens"] ??
                    item["cached_tokens"] ??
                    item["cachedTokens"]
                )
                let directCacheHitRate = cacheHitRateValue(
                    item["cache_hit_rate"] ??
                    item["cacheHitRate"] ??
                    item["cache_read_rate"] ??
                    item["cacheReadRate"]
                )
                if let prompt {
                    aggregate.tokenCount += prompt
                    aggregate.promptTokenCount += prompt
                    aggregate.hasTokenCount = true
                    aggregate.hasPromptTokenCount = true
                }
                if let completion { aggregate.tokenCount += completion; aggregate.hasTokenCount = true }
                if let cacheRead {
                    aggregate.cacheReadTokenCount += cacheRead
                    aggregate.hasCacheReadTokenCount = true
                }
                if let directCacheHitRate {
                    // Prefer the provider-supplied rate when available. Weight it by
                    // prompt tokens so a small request does not distort a model's
                    // aggregate; fall back to one request when token counts are absent.
                    let weight = Decimal(max(prompt ?? 1, 1))
                    aggregate.directCacheHitRateTotal += directCacheHitRate * weight
                    aggregate.directCacheHitRateWeight += weight
                    aggregate.hasDirectCacheHitRate = true
                }
                if let quota = decimalValue(item["quota"]) {
                    aggregate.quota += quota
                    aggregate.hasQuota = true
                }
                aggregates[model] = aggregate
            }

            received += pageData.items.count
            if let expectedTotal, Int64(received) >= expectedTotal { break }
            if pageData.items.count < 100 { break }
            page += 1
        }

        return aggregates.map { model, aggregate in
            ModelUsageSummary(
                modelName: model,
                tokenCount: aggregate.hasTokenCount ? aggregate.tokenCount : nil,
                requestCount: aggregate.requestCount,
                cacheHitRate: {
                    if aggregate.hasDirectCacheHitRate, aggregate.directCacheHitRateWeight > 0 {
                        return aggregate.directCacheHitRateTotal / aggregate.directCacheHitRateWeight
                    }
                    guard aggregate.hasCacheReadTokenCount,
                          aggregate.hasPromptTokenCount,
                          aggregate.promptTokenCount > 0 else { return nil }
                    return min(Decimal(1), max(Decimal.zero, Decimal(aggregate.cacheReadTokenCount) / Decimal(aggregate.promptTokenCount)))
                }(),
                spend: aggregate.hasQuota ? MoneyValue(amount: aggregate.quota / quotaPerUnit, currency: currency) : nil
            )
        }.sorted { lhs, rhs in
            (lhs.spend?.amount ?? .zero) > (rhs.spend?.amount ?? .zero)
        }
    }

    private func parseLogPage(_ data: Data) throws -> (items: [[String: Any]], total: Int64?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] else { throw ProviderError.incompatibleResponse }
        let object = payload as? [String: Any]
        let items = (object?["items"] as? [[String: Any]]) ?? (payload as? [[String: Any]])
        guard let items else { throw ProviderError.incompatibleResponse }
        let total = int64Value(object?["total"])
        return (items, total)
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    private func decimalValue(_ value: Any?) -> Decimal? {
        if let number = value as? NSNumber { return Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX")) }
        if let string = value as? String { return Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) }
        return nil
    }

    /// Normalizes either a 0...1 ratio or a provider response expressed as a
    /// 0...100 percentage. Invalid values remain unavailable rather than being
    /// coerced into a fake cache-read rate.
    private func cacheHitRateValue(_ value: Any?) -> Decimal? {
        guard var rate = decimalValue(value) else { return nil }
        if rate > 1, rate <= 100 { rate /= 100 }
        guard (0...1).contains(rate) else { return nil }
        return rate
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ProviderError.incompatibleResponse
        }
    }
}

private struct PipioEnvelope<Value: Decodable>: Decodable {
    let success: Bool?
    let data: Value?
}

private struct PipioStatusData: Decodable {
    let quotaPerUnit: Decimal?
    let creditCurrency: String?
    let quotaDisplayType: String?
}

private struct PipioUserData: Decodable {
    let quota: Decimal?
    let usedQuota: Decimal?
    let requestCount: Int64?
}

private struct PipioStatData: Decodable {
    let quota: Decimal?
    let rpm: Int64?
    let tpm: Int64?
}

private extension Currency {
    init?(providerCode: String?) {
        guard let normalized = providerCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else {
            return nil
        }
        switch normalized {
        case "CNY", "RMB", "¥", "￥": self = .cny
        case "USD", "$": self = .usd
        default: return nil
        }
    }
}
