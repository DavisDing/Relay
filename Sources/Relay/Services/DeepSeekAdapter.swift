import Foundation

public struct DeepSeekAdapter: ProviderAdapter {
    public let kind: ProviderKind = .deepseek
    private let client: any HTTPClient
    private static let balanceOrigin = URL(string: "https://api.deepseek.com")!

    public init(client: any HTTPClient = URLSessionHTTPClient()) {
        self.client = client
    }

    public func fetchAccountRate(for account: AccountConfiguration, credential: ProviderCredential) async throws -> AccountRate {
        try validateCredential(credential)
        _ = try ProviderURLNormalizer.secureOrigin(from: account.siteOrigin)
        let balance = try await fetchBalance(account: account, credential: credential)
        let conversion: Decimal?
        switch balance.currency {
        case .cny:
            conversion = 1
        case .usd:
            conversion = account.manualUSDToCNY.flatMap { USDToCNYRate.isValid($0) ? $0 : nil }
        }
        return AccountRate(
            accountID: account.id,
            source: .providerNativeCurrency,
            nativeCurrency: balance.currency,
            quotaPerUnit: nil,
            conversionToCNY: conversion,
            fetchedAt: Date(),
            expiresAt: nil
        )
    }

    public func validateAccount(_ account: AccountConfiguration, credential: ProviderCredential) async throws {
        _ = try await fetchBalance(account: account, credential: credential)
    }

    /// Historical usage is opt-in. The API key is never sent to the platform
    /// usage endpoints; only the optional, user-entered userToken is used there.
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
            calendar: DeepSeekUsageService.historyCalendar
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
        let balance = try await fetchBalance(account: account, credential: credential)
        guard rate.accountID == account.id, rate.nativeCurrency == balance.currency else {
            throw ProviderError.missingRate
        }

        guard normalizedUserToken(from: credential) != nil else {
            return ProviderSnapshot(
                accountID: account.id,
                balance: balance,
                todaySpend: nil,
                monthSpend: nil,
                requestCount: nil,
                capabilities: [.balance],
                freshness: .fresh,
                fetchedAt: now,
                rate: rate
            )
        }

        do {
            let summary = try await DeepSeekUsageService(client: client).fetchCurrentMonth(
                accountID: account.id,
                now: now,
                calendar: DeepSeekUsageService.historyCalendar,
                credential: credential
            )
            guard let summary else {
                return ProviderSnapshot(
                    accountID: account.id,
                    balance: balance,
                    todaySpend: nil,
                    monthSpend: nil,
                    requestCount: nil,
                    capabilities: [.balance],
                    freshness: .partial,
                    fetchedAt: now,
                    rate: rate
                )
            }
            var capabilities: ProviderCapabilities = [.balance]
            if summary.todaySpend != nil { capabilities.insert(.todayUsage) }
            if summary.monthSpend != nil { capabilities.insert(.monthlyUsage) }
            if summary.requestCount != nil { capabilities.insert(.requestCount) }
            if let models = summary.modelUsages, !models.isEmpty { capabilities.insert(.modelUsage) }
            return ProviderSnapshot(
                accountID: account.id,
                balance: balance,
                todaySpend: summary.todaySpend,
                monthSpend: summary.monthSpend,
                requestCount: summary.requestCount,
                modelUsages: summary.modelUsages,
                capabilities: capabilities,
                freshness: .fresh,
                fetchedAt: now,
                rate: rate
            )
        } catch {
            // Balance is an independent official API. Keep it usable when the
            // optional platform session token is expired or the internal usage
            // endpoint changes; the snapshot explicitly records partial data.
            return ProviderSnapshot(
                accountID: account.id,
                balance: balance,
                todaySpend: nil,
                monthSpend: nil,
                requestCount: nil,
                capabilities: [.balance],
                freshness: .partial,
                fetchedAt: now,
                rate: rate
            )
        }
    }

    public func fetchDailyUsage(
        for account: AccountConfiguration,
        credential: ProviderCredential,
        rate: AccountRate,
        endingAt: Date,
        days: Int,
        calendar _: Calendar
    ) async throws -> [DailyUsageRecord] {
        guard normalizedUserToken(from: credential) != nil else { return [] }
        let historyCalendar = DeepSeekUsageService.historyCalendar
        let clampedDays = min(max(days, 1), 30)
        let end = historyCalendar.startOfDay(for: endingAt)
        guard let start = historyCalendar.date(byAdding: .day, value: -(clampedDays - 1), to: end) else {
            throw DeepSeekUsageServiceError.invalidDateRange
        }
        let report = try await fetchUsage(
            for: account,
            credential: credential,
            startAt: start,
            endAt: end,
            calendar: historyCalendar
        )
        return (report.daily ?? []).compactMap { row in
            guard let spend = row.spend else { return nil }
            return DailyUsageRecord(
                accountID: account.id,
                day: historyCalendar.startOfDay(for: row.day),
                spend: spend,
                updatedAt: report.fetchedAt
            )
        }
    }

    private func validateCredential(_ credential: ProviderCredential) throws {
        guard !credential.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.invalidCredential
        }
    }

    private func normalizedUserToken(from credential: ProviderCredential) -> String? {
        let value = credential.deepSeekUserToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func fetchBalance(account: AccountConfiguration, credential: ProviderCredential) async throws -> MoneyValue {
        try validateCredential(credential)
        let origin = try ProviderURLNormalizer.secureOrigin(from: account.siteOrigin)
        guard origin == Self.balanceOrigin else { throw ProviderError.invalidBaseURL }
        let url = Self.balanceOrigin.appendingPathComponent("user/balance")
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
            // DeepSeek normally returns one balance. Prefer CNY when several
            // balances are returned, otherwise use the first supported one.
            let info = payload.balanceInfos.first(where: { $0.currency.uppercased() == "CNY" })
                ?? payload.balanceInfos.first
            guard let info,
                  let currency = Currency(rawValue: info.currency.uppercased()),
                  let amount = Decimal(string: info.totalBalance, locale: Locale(identifier: "en_US_POSIX")) else {
                throw ProviderError.incompatibleResponse
            }
            return MoneyValue(amount: amount, currency: currency)
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
