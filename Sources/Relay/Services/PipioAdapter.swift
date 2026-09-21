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
            conversionToCNY: currency == .cny ? 1 : envelope.data?.usdExchangeRate.flatMap { $0 > 0 ? $0 : nil },
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

        async let monthResult = fetchStat(
            urls: urls,
            credential: credential,
            range: DateInterval(start: monthStart, end: now)
        )
        async let dashboardResult = fetchDashboardUsage(
            urls: urls,
            credential: credential,
            range: DateInterval(start: dayStart, end: now),
            quotaPerUnit: quotaPerUnit,
            currency: rate.nativeCurrency
        )

        let month = try? await monthResult
        let dashboard = try? await dashboardResult
        let modelUsages = dashboard?.models
        let currency = rate.nativeCurrency
        let balance = current.quota.map { MoneyValue(amount: $0 / quotaPerUnit, currency: currency) }
        let todaySpend = dashboard?.spend
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
            freshness: (todaySpend != nil && monthSpend != nil) ? .fresh : .partial,
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
        // completed calendar day for history. Today's record is already seeded
        // from the snapshot's dashboard data; never overwrite it with log/stat.
        for offset in 1..<count {
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

    private func fetchDashboardUsage(
        urls: NormalizedProviderURLs,
        credential: ProviderCredential,
        range: DateInterval,
        quotaPerUnit: Decimal,
        currency: Currency
    ) async throws -> PipioDashboardParser.Usage {
        var components = URLComponents(
            url: urls.managementBaseURL.appendingPathComponent("data/self"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "start_timestamp", value: String(Int64(range.start.timeIntervalSince1970))),
            URLQueryItem(name: "end_timestamp", value: String(Int64(range.end.timeIntervalSince1970)))
        ]
        guard let url = components?.url else { throw ProviderError.invalidBaseURL }
        let (data, response) = try await client.data(for: authorizedRequest(url: url, credential: credential))
        try HTTPResponseValidator.validate(response)
        return try PipioDashboardParser.usage(from: data, range: range, quotaPerUnit: quotaPerUnit, currency: currency)
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
    let usdExchangeRate: Decimal?
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
