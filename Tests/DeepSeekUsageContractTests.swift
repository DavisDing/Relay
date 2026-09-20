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
    private(set) var requests: [URLRequest] = []
    var responseData: Data
    var response: HTTPURLResponse

    init(
        responseData: Data = Data(),
        statusCode: Int = 200
    ) {
        self.responseData = responseData
        self.response = HTTPURLResponse(
            url: URL(string: "https://api.deepseek.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (responseData, response)
    }
}

@main
struct DeepSeekUsageContractTests {
    static func main() async {
        do {
            try await testUnsupportedReportDoesNotInventZeros()
            try await testUnsupportedProbeDoesNotCallUnknownEndpoint()
            try await testInputValidation()
            try await testExistingBalanceFlowRemainsOfficial()
            print("PASSED: DeepSeek usage contract tests")
        } catch {
            fputs("FAILED: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testUnsupportedReportDoesNotInventZeros() async throws {
        let client = StubHTTPClient()
        let accountID = UUID()
        let query = DeepSeekUsageQuery(
            accountID: accountID,
            siteOrigin: URL(string: "https://api.deepseek.com")!,
            startAt: Date(timeIntervalSince1970: 100),
            endAt: Date(timeIntervalSince1970: 200),
            calendar: Calendar(identifier: .gregorian)
        )
        let report = try await DeepSeekUsageService(client: client).fetchUsage(
            query: query,
            credential: ProviderCredential(secret: "test-key")
        )

        try require(report.accountID == accountID, "report must preserve account ID")
        try require(report.coverage == .unsupported, "unsupported API must be explicit")
        try require(report.daily == nil, "unsupported daily usage must be nil")
        try require(report.models == nil, "unsupported model usage must be nil")
        try require(
            report.unavailableReason == .officialAPIHasNoHistoricalOrModelUsageEndpoint,
            "unsupported report must explain the official API limitation"
        )
        try require(client.requests.isEmpty, "unsupported capability must not call guessed endpoints")
    }

    private static func testUnsupportedProbeDoesNotCallUnknownEndpoint() async throws {
        let client = StubHTTPClient()
        let service = DeepSeekUsageService(client: client)
        try require(service.probe() == .unsupported, "probe must report unsupported")
        try require(client.requests.isEmpty, "probe must not perform a private or guessed request")
    }

    private static func testInputValidation() async throws {
        let service = DeepSeekUsageService(client: StubHTTPClient())
        let validOrigin = URL(string: "https://api.deepseek.com")!

        do {
            _ = try await service.fetchUsage(
                query: DeepSeekUsageQuery(
                    accountID: UUID(),
                    siteOrigin: validOrigin,
                    startAt: Date(timeIntervalSince1970: 2),
                    endAt: Date(timeIntervalSince1970: 1)
                ),
                credential: ProviderCredential(secret: "test-key")
            )
            throw ContractTestFailure.failed("reverse date range must fail")
        } catch let error as DeepSeekUsageServiceError {
            try require(error == .invalidDateRange, "reverse date range error must be typed")
        }

        do {
            _ = try await service.fetchUsage(
                query: DeepSeekUsageQuery(
                    accountID: UUID(),
                    siteOrigin: validOrigin,
                    startAt: Date(timeIntervalSince1970: 1),
                    endAt: Date(timeIntervalSince1970: 2)
                ),
                credential: ProviderCredential(secret: "   ")
            )
            throw ContractTestFailure.failed("empty credential must fail")
        } catch let error as ProviderError {
            try require(error == .invalidCredential, "empty credential error must be typed")
        }

        do {
            _ = try await service.fetchUsage(
                query: DeepSeekUsageQuery(
                    accountID: UUID(),
                    siteOrigin: URL(string: "http://api.deepseek.com")!,
                    startAt: Date(timeIntervalSince1970: 1),
                    endAt: Date(timeIntervalSince1970: 2)
                ),
                credential: ProviderCredential(secret: "test-key")
            )
            throw ContractTestFailure.failed("non-HTTPS origin must fail")
        } catch let error as ProviderError {
            try require(error == .insecureBaseURL, "non-HTTPS origin error must be typed")
        }
    }

    private static func testExistingBalanceFlowRemainsOfficial() async throws {
        let client = StubHTTPClient(
            responseData: Data("{\"is_available\":true,\"balance_infos\":[{\"currency\":\"CNY\",\"total_balance\":\"12.50\"}]}".utf8)
        )
        let adapter = DeepSeekAdapter(client: client)
        let account = AccountConfiguration(
            displayName: "DeepSeek",
            providerKind: .deepseek,
            siteOrigin: URL(string: "https://api.deepseek.com")!
        )
        let credential = ProviderCredential(secret: "test-key")
        let rate = try await adapter.fetchAccountRate(for: account, credential: credential)
        let snapshot = try await adapter.fetchSnapshot(
            for: account,
            credential: credential,
            rate: rate,
            now: Date(timeIntervalSince1970: 100),
            calendar: Calendar(identifier: .gregorian)
        )

        try require(snapshot.balance?.amount == Decimal(string: "12.50"), "balance amount must remain compatible")
        try require(client.requests.count == 1, "snapshot should use the existing balance endpoint")
        for request in client.requests {
            try require(request.httpMethod == "GET", "balance endpoint must remain GET")
            try require(request.url?.path == "/user/balance", "balance path must remain official /user/balance")
            try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "bearer header must remain")
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ContractTestFailure.failed(message) }
    }
}
