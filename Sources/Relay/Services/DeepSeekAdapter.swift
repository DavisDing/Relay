import Foundation

public struct DeepSeekAdapter: ProviderAdapter {
    public let kind: ProviderKind = .deepseek
    private let client: any HTTPClient

    public init(client: any HTTPClient = URLSessionHTTPClient()) {
        self.client = client
    }

    public func fetchAccountRate(for account: AccountConfiguration, credential: ProviderCredential) async throws -> AccountRate {
        try validateCredential(credential)
        _ = try ProviderURLNormalizer.secureOrigin(from: account.siteOrigin)
        let now = Date()
        return AccountRate(
            accountID: account.id,
            source: .providerNativeCurrency,
            nativeCurrency: .cny,
            quotaPerUnit: nil,
            conversionToCNY: 1,
            fetchedAt: now,
            expiresAt: nil
        )
    }

    public func validateAccount(_ account: AccountConfiguration, credential: ProviderCredential) async throws {
        _ = try await fetchBalance(account: account, credential: credential)
    }

    /// Queries the usage capability without changing the existing balance path.
    /// The official DeepSeek API currently does not expose historical or
    /// account-level model usage, so the service returns `.unsupported` with
    /// nil usage collections and does not call undocumented endpoints.
    public func fetchUsage(
        for account: AccountConfiguration,
        credential: ProviderCredential,
        startAt: Date,
        endAt: Date,
        calendar: Calendar = .current
    ) async throws -> DeepSeekUsageReport {
        let query = DeepSeekUsageQuery(
            accountID: account.id,
            siteOrigin: account.siteOrigin,
            startAt: startAt,
            endAt: endAt,
            calendar: calendar
        )
        return try await DeepSeekUsageService(client: client).fetchUsage(
            query: query,
            credential: credential
        )
    }

    public func fetchSnapshot(
        for account: AccountConfiguration,
        credential: ProviderCredential,
        rate: AccountRate,
        now: Date,
        calendar: Calendar
    ) async throws -> ProviderSnapshot {
        guard rate.accountID == account.id, rate.nativeCurrency == .cny else {
            throw ProviderError.missingRate
        }
        let balance = try await fetchBalance(account: account, credential: credential)
        return ProviderSnapshot(
            accountID: account.id,
            balance: MoneyValue(amount: balance, currency: .cny),
            todaySpend: nil,
            monthSpend: nil,
            requestCount: nil,
            capabilities: [.balance],
            freshness: .fresh,
            fetchedAt: now,
            rate: rate
        )
    }

    private func validateCredential(_ credential: ProviderCredential) throws {
        guard !credential.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.invalidCredential
        }
    }

    private func fetchBalance(account: AccountConfiguration, credential: ProviderCredential) async throws -> Decimal {
        try validateCredential(credential)
        let origin = try ProviderURLNormalizer.secureOrigin(from: account.siteOrigin)
        let url = origin.appendingPathComponent("user/balance")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credential.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await client.data(for: request)
        try HTTPResponseValidator.validate(response)

        do {
            let payload = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
            guard payload.isAvailable else { throw ProviderError.incompatibleResponse }
            guard let cny = payload.balanceInfos.first(where: { $0.currency.uppercased() == "CNY" }),
                  let amount = Decimal(string: cny.totalBalance, locale: Locale(identifier: "en_US_POSIX")) else {
                throw ProviderError.incompatibleResponse
            }
            return amount
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.incompatibleResponse
        }
    }
}

private struct DeepSeekBalanceResponse: Decodable {
    let isAvailable: Bool
    let balanceInfos: [DeepSeekBalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

private struct DeepSeekBalanceInfo: Decodable {
    let currency: String
    let totalBalance: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
    }
}
