import Foundation

private enum ContractTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    private let handler: (URLRequest) -> (Data, HTTPURLResponse)

    init(handler: @escaping (URLRequest) -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        return handler(request)
    }

    func recordedRequests() -> [URLRequest] {
        lock.withLock { requests }
    }
}

@main
struct DeepSeekUsageContractTests {
    private static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }()

    static func main() async {
        do {
            try await testMissingUserTokenIsExplicitAndDoesNotCallPlatform()
            try await testPlatformUsageUsesUserTokenAndExpectedEndpoints()
            try await testUsagePayloadAggregation()
            try await testUnauthorizedUserTokenIsTyped()
            try await testBalanceUsesAPIKeyOnly()
            try await testBalanceOnlySnapshotAndPlatformFailure()
            try await testSevenDayHistoryAndLocalTodayBoundary()
            try testLegacyCredentialDecodesWithoutUserToken()
            try testSyncDataDoesNotContainCredentials()
            try await testInputValidation()
            print("PASSED: DeepSeek usage contract tests")
        } catch {
            fputs("FAILED: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testMissingUserTokenIsExplicitAndDoesNotCallPlatform() async throws {
        let client = StubHTTPClient { _ in (Data(), response(statusCode: 500)) }
        let accountID = UUID()
        let report = try await DeepSeekUsageService(client: client).fetchUsage(
            query: query(accountID: accountID),
            credential: ProviderCredential(secret: "api-key")
        )

        try require(report.accountID == accountID, "report must preserve account ID")
        try require(report.coverage == .unsupported, "missing userToken must be unsupported")
        try require(report.daily == nil, "missing userToken must not invent daily usage")
        try require(report.models == nil, "missing userToken must not invent model usage")
        try require(report.unavailableReason == .userTokenNotConfigured, "missing userToken reason must be explicit")
        try require(client.recordedRequests().isEmpty, "missing userToken must not call platform endpoints")
    }

    private static func testPlatformUsageUsesUserTokenAndExpectedEndpoints() async throws {
        let client = StubHTTPClient { request in
            switch request.url?.path {
            case "/api/v0/usage/amount": (amountFixture, response())
            case "/api/v0/usage/cost": (costFixture, response())
            default: (Data(), response(statusCode: 404))
            }
        }
        _ = try await DeepSeekUsageService(client: client).fetchUsage(
            query: query(accountID: UUID()),
            credential: ProviderCredential(secret: "api-key", deepSeekUserToken: "platform-token")
        )

        let requests = client.recordedRequests()
        try require(requests.count == 2, "amount and cost endpoints must both be requested")
        for request in requests {
            try require(request.url?.host == "platform.deepseek.com", "usage host must be platform.deepseek.com")
            try require(request.url?.path == "/api/v0/usage/amount" || request.url?.path == "/api/v0/usage/cost", "usage path must be official platform endpoint")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let queryItems = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            try require(queryItems["month"] == "9", "usage query must include month")
            try require(queryItems["year"] == "2026", "usage query must include year")
            try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer platform-token", "usage must use userToken, not API key")
            try require(request.value(forHTTPHeaderField: "User-Agent")?.contains("Mozilla") == true, "usage must send browser-style User-Agent")
            try require(request.value(forHTTPHeaderField: "Referer") == "https://platform.deepseek.com/usage", "usage must send platform Referer")
        }
    }

    private static func testUsagePayloadAggregation() async throws {
        let client = StubHTTPClient { request in
            request.url?.path == "/api/v0/usage/amount"
                ? (amountFixture, response())
                : (costFixture, response())
        }
        let report = try await DeepSeekUsageService(client: client).fetchUsage(
            query: DeepSeekUsageQuery(
                accountID: UUID(),
                siteOrigin: URL(string: "https://api.deepseek.com")!,
                startAt: date("2026-09-22"),
                endAt: date("2026-09-23"),
                calendar: calendar
            ),
            credential: ProviderCredential(secret: "api-key", deepSeekUserToken: "platform-token")
        )

        try require(report.coverage == .complete, "valid platform responses must be complete")
        try require(report.unavailableReason == nil, "complete report must not have an unavailable reason")
        try require(report.daily?.count == 2, "daily amount and cost should aggregate by date")
        let chat = report.models?.first(where: { $0.modelName == "deepseek-chat" })
        try require(chat?.tokenCount == 1_100, "model token count must include all token categories")
        try require(chat?.requestCount == 2, "model request count must be aggregated")
        try require(chat?.spend?.amount == Decimal(string: "0.12"), "model spend must come from cost endpoint")
        let firstDay = report.daily?.first(where: { DeepSeekUsageService.historyCalendar.component(.day, from: $0.day) == 22 })
        try require(firstDay?.tokenCount == 550, "daily token count must be aggregated")
        try require(firstDay?.requestCount == 1, "daily request count must be aggregated")
        try require(firstDay?.spend?.amount == Decimal(string: "0.05"), "daily spend must be aggregated")
    }

    private static func testUnauthorizedUserTokenIsTyped() async throws {
        let client = StubHTTPClient { _ in (Data(), response(statusCode: 401)) }
        do {
            _ = try await DeepSeekUsageService(client: client).fetchUsage(
                query: query(accountID: UUID()),
                credential: ProviderCredential(secret: "api-key", deepSeekUserToken: "expired-token")
            )
            throw ContractTestFailure.failed("401 must throw userTokenUnauthorized")
        } catch let error as DeepSeekUsageServiceError {
            try require(error == .userTokenUnauthorized, "401 must map to userTokenUnauthorized")
        }
    }

    private static func testBalanceUsesAPIKeyOnly() async throws {
        let client = StubHTTPClient { _ in
            let data = try! JSONSerialization.data(withJSONObject: [
                "is_available": true,
                "balance_infos": [["currency": "CNY", "total_balance": "12.34", "granted_balance": "0", "topped_up_balance": "12.34"]]
            ])
            return (data, response())
        }
        let account = AccountConfiguration(
            displayName: "DeepSeek",
            providerKind: .deepseek,
            siteOrigin: URL(string: "https://api.deepseek.com")!
        )
        let rate = try await DeepSeekAdapter(client: client).fetchAccountRate(
            for: account,
            credential: ProviderCredential(secret: "api-key", deepSeekUserToken: "platform-token")
        )
        try require(rate.nativeCurrency == .cny, "balance currency must be preserved")
        let requests = client.recordedRequests()
        try require(requests.count == 1, "balance probe should make one balance request")
        try require(requests[0].url?.path == "/user/balance", "balance path must be /user/balance")
        try require(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer api-key", "balance must use API key")
        try require(requests[0].value(forHTTPHeaderField: "Authorization") != "Bearer platform-token", "userToken must not be used for balance")
    }

    private static func testBalanceOnlySnapshotAndPlatformFailure() async throws {
        let client = StubHTTPClient { request in
            if request.url?.host == "api.deepseek.com" {
                return (Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"12.34"}]}"#.utf8), response())
            }
            return (Data(), response(statusCode: 401))
        }
        let account = AccountConfiguration(
            displayName: "DeepSeek", providerKind: .deepseek,
            siteOrigin: URL(string: "https://api.deepseek.com")!
        )
        let adapter = DeepSeekAdapter(client: client)
        let noToken = ProviderCredential(secret: "api-key")
        let rate = try await adapter.fetchAccountRate(for: account, credential: noToken)
        let balanceOnly = try await adapter.fetchSnapshot(
            for: account, credential: noToken, rate: rate, now: date("2026-09-23"), calendar: calendar
        )
        try require(balanceOnly.freshness == .fresh && balanceOnly.balance?.amount == Decimal(string: "12.34"), "balance-only snapshot must be available")
        try require(balanceOnly.monthSpend == nil && balanceOnly.todaySpend == nil, "absent token must leave usage unknown")
        try require(client.recordedRequests().allSatisfy { $0.url?.host == "api.deepseek.com" }, "no token must not call platform")

        let withToken = ProviderCredential(secret: "api-key", deepSeekUserToken: "expired-token")
        let partial = try await adapter.fetchSnapshot(
            for: account, credential: withToken, rate: rate, now: date("2026-09-23"), calendar: calendar
        )
        try require(partial.freshness == .partial, "invalid platform token must mark usage partial")
        try require(partial.balance?.amount == Decimal(string: "12.34"), "platform failure must preserve official balance")
        try require(partial.monthSpend == nil, "platform failure must not invent zero consumption")
        try require(client.recordedRequests().contains { $0.url?.host == "platform.deepseek.com" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer expired-token" }, "platform authentication must use userToken")
    }

    private static func testSevenDayHistoryAndLocalTodayBoundary() async throws {
        let client = StubHTTPClient { request in
            request.url?.path == "/api/v0/usage/amount"
                ? (amountFixture, response())
                : (costFixture, response())
        }
        let account = AccountConfiguration(
            displayName: "DeepSeek", providerKind: .deepseek,
            siteOrigin: URL(string: "https://api.deepseek.com")!
        )
        let credential = ProviderCredential(secret: "api-key", deepSeekUserToken: "platform-token")
        let rate = AccountRate(accountID: account.id, source: .providerNativeCurrency, nativeCurrency: .cny, conversionToCNY: 1)
        let days = try await DeepSeekAdapter(client: client).fetchDailyUsage(
            for: account, credential: credential, rate: rate,
            endingAt: date("2026-09-23"), days: 7, calendar: calendar
        )
        try require(days.count == 2, "seven-day query must return available dated cost rows")
        try require(days.first?.spend?.amount == Decimal(string: "0.05"), "history must use cost endpoint")
        let historyCalendar = DeepSeekUsageService.historyCalendar
        try require(historyCalendar.component(.day, from: days.first!.day) == 22, "history rows must keep GMT+8 day boundaries")
        try require(client.recordedRequests().count == 2, "seven days within one month need one amount/cost pair")

        var china = calendar
        china.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let chinaSummary = try await DeepSeekUsageService(client: client).fetchCurrentMonth(
            accountID: account.id, now: date("2026-09-23"), calendar: china, credential: credential
        )
        try require(chinaSummary?.todaySpend?.amount == Decimal(string: "0.07"), "today spend must use GMT+8 day boundaries")
        try require(chinaSummary?.monthSpend?.amount == Decimal(string: "0.12"), "monthly spend remains available")
    }

    private static func testLegacyCredentialDecodesWithoutUserToken() throws {
        let data = Data("{\"schemaVersion\":1,\"secret\":\"api-key\",\"pipioUserID\":null}".utf8)
        let credential = try JSONDecoder().decode(ProviderCredential.self, from: data)
        try require(credential.secret == "api-key", "legacy credential secret must decode")
        try require(credential.deepSeekUserToken == nil, "legacy credential must default userToken to nil")
    }

    private static func testSyncDataDoesNotContainCredentials() throws {
        let account = AccountConfiguration(
            displayName: "DeepSeek",
            providerKind: .deepseek,
            siteOrigin: URL(string: "https://api.deepseek.com")!
        )
        let data = try JSONEncoder().encode(RelaySyncData(
            accounts: [account],
            snapshots: [],
            dailyUsage: [],
            settings: RelaySettings()
        ))
        let encoded = String(decoding: data, as: UTF8.self)
        try require(!encoded.contains("api-key"), "sync data must not contain API key")
        try require(!encoded.contains("platform-token"), "sync data must not contain userToken")
        try require(!encoded.contains("deepSeekUserToken"), "sync schema must not include credential fields")
    }

    private static func testInputValidation() async throws {
        let service = DeepSeekUsageService(client: StubHTTPClient { _ in (Data(), response(statusCode: 500)) })
        do {
            _ = try await service.fetchUsage(
                query: DeepSeekUsageQuery(
                    accountID: UUID(),
                    siteOrigin: URL(string: "https://api.deepseek.com")!,
                    startAt: date("2026-09-23"),
                    endAt: date("2026-09-22"),
                    calendar: calendar
                ),
                credential: ProviderCredential(secret: "api-key", deepSeekUserToken: "token")
            )
            throw ContractTestFailure.failed("reverse date range must fail")
        } catch let error as DeepSeekUsageServiceError {
            try require(error == .invalidDateRange, "reverse date range error must be typed")
        }
    }

    private static func query(accountID: UUID) -> DeepSeekUsageQuery {
        DeepSeekUsageQuery(
            accountID: accountID,
            siteOrigin: URL(string: "https://api.deepseek.com")!,
            startAt: date("2026-09-22"),
            endAt: date("2026-09-23"),
            calendar: calendar
        )
    }

    private static func date(_ value: String) -> Date {
        let parts = value.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    private static func response(statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://platform.deepseek.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ContractTestFailure.failed(message) }
    }

    private static let amountFixture = Data(#"""
{
      "data": {"biz_data": {
        "total": [
          {"model":"deepseek-chat","usage":[
            {"type":"REQUEST","amount":"2"},
            {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"300"},
            {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"500"},
            {"type":"RESPONSE_TOKEN","amount":"300"}
          ]}
        ],
        "days": [
          {"date":"2026-09-22","data":[{"model":"deepseek-chat","usage":[
            {"type":"REQUEST","amount":"1"},
            {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"150"},
            {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"250"},
            {"type":"RESPONSE_TOKEN","amount":"150"}
          ]}]},
          {"date":"2026-09-23","data":[{"model":"deepseek-chat","usage":[
            {"type":"REQUEST","amount":"1"},
            {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"150"},
            {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"250"},
            {"type":"RESPONSE_TOKEN","amount":"150"}
          ]}]}
        ]
      }}
    }
"""#.utf8)

    private static let costFixture = Data(#"""
{
      "data": {"biz_data": [{
        "currency":"CNY",
        "total": [{"model":"deepseek-chat","usage":[
          {"type":"REQUEST","amount":"0"},
          {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"0.03"},
          {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"0.05"},
          {"type":"RESPONSE_TOKEN","amount":"0.04"}
        ]}],
        "days": [
          {"date":"2026-09-22","data":[{"model":"deepseek-chat","usage":[
            {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"0.01"},
            {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"0.02"},
            {"type":"RESPONSE_TOKEN","amount":"0.02"}
          ]}]},
          {"date":"2026-09-23","data":[{"model":"deepseek-chat","usage":[
            {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"0.02"},
            {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"0.03"},
            {"type":"RESPONSE_TOKEN","amount":"0.02"}
          ]}]}
        ]
      }]}
    }
"""#.utf8)
}
