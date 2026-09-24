import Foundation

private struct WorkBuddyCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func workBuddyVerify(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw WorkBuddyCheckFailure(description: message) }
}

private actor WorkBuddyFixtureClient: HTTPClient {
    private var statusPayloads: [Data]
    private(set) var requests: [URLRequest] = []

    init(statusPayloads: [Data]) {
        self.statusPayloads = statusPayloads
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let url = request.url else { throw WorkBuddyCheckFailure(description: "missing request URL") }
        switch url.path {
        case "/status":
            guard !statusPayloads.isEmpty else {
                throw WorkBuddyCheckFailure(description: "unexpected third status request")
            }
            let payload = statusPayloads.removeFirst()
            return (payload, response(for: url))
        case "/v1/stats":
            let payload = Data(#"{"since":"2026-09-24T00:00:00Z","total":{"requests":2,"success":2,"failed":0,"streaming":0,"prompt_tokens":0,"completion_tokens":0,"total_tokens":0,"cache_hit_tokens":0,"cache_miss_tokens":0,"cache_write_tokens":0,"credit":1.5},"models":[]}"#.utf8)
            return (payload, response(for: url))
        default:
            throw WorkBuddyCheckFailure(description: "unexpected endpoint " + url.path)
        }
    }

    private func response(for url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

enum WorkBuddy2APIContractChecks {
    static func run() async throws {
        let first = Data(#"{"accounts":[{"uid":"a-1","nickname":"alpha","credits":100,"disabled":false,"cooling":false}]}"#.utf8)
        let second = Data(#"{"accounts":[{"uid":"a-1","nickname":"alpha","credits":125,"disabled":false,"cooling":false}]}"#.utf8)
        let client = WorkBuddyFixtureClient(statusPayloads: [first, second])
        let adapter = WorkBuddy2APIAdapter(client: client)
        let account = AccountConfiguration(
            displayName: "WorkBuddy fixture",
            providerKind: .workbuddy2api,
            siteOrigin: URL(string: "https://gateway.example.invalid")!
        )
        let credential = ProviderCredential(secret: "fixture-token")
        let rate = AccountRate(
            accountID: account.id,
            source: .providerNativeCurrency,
            nativeCurrency: .cny,
            fetchedAt: Date(),
            expiresAt: nil
        )

        let firstSnapshot = try await adapter.fetchSnapshot(
            for: account, credential: credential, rate: rate, now: Date(), calendar: .current
        )
        let secondSnapshot = try await adapter.fetchSnapshot(
            for: account, credential: credential, rate: rate, now: Date(), calendar: .current
        )
        let firstPoints = firstSnapshot.subAccounts?.first?.availablePoints
        let secondPoints = secondSnapshot.subAccounts?.first?.availablePoints
        try workBuddyVerify(firstPoints == Decimal(100), "first status response was not decoded")
        try workBuddyVerify(secondPoints == Decimal(125), "manual refresh did not use the newer status response")
        try workBuddyVerify(firstSnapshot.requestCount == 2, "stats request count was not decoded")
        try workBuddyVerify(firstSnapshot.workBuddyStats?.total.credit == Decimal(string: "1.5"), "stats credit was not decoded")
        try workBuddyVerify(firstSnapshot.capabilities.contains(.requestCount), "stats request-count capability was not set")
        try workBuddyVerify(firstSnapshot.capabilities.contains(.modelUsage), "stats model-usage capability was not set")

        let requests = await client.requests
        let statusRequests = requests.filter { $0.url?.path == "/status" }
        let statsRequests = requests.filter { $0.url?.path == "/v1/stats" }
        try workBuddyVerify(statusRequests.count == 2, "expected one fresh status request per snapshot")
        try workBuddyVerify(statsRequests.count == 2, "expected one fresh stats request per snapshot")
        for request in statusRequests + statsRequests {
            try workBuddyVerify(request.cachePolicy == .reloadIgnoringLocalCacheData, "status request must bypass URL loading cache")
            try workBuddyVerify(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache", "status request must send Cache-Control: no-cache")
            try workBuddyVerify(request.value(forHTTPHeaderField: "Pragma") == "no-cache", "status request must send Pragma: no-cache")
        }
        print("PASSED: workbuddy2api manual refresh requests fresh credits and stats")
    }
}
