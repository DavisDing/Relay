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
        let first = Data(#"{"accounts":[{"uid":"a-1","nickname":"alpha","credits":100,"disabled":false,"cooling":false,"reason":"账户调用失败"}]}"#.utf8)
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
        try workBuddyVerify(firstSnapshot.subAccounts?.first?.statusMessage == "账户调用失败", "sub-account failure reason was not preserved")
        try workBuddyVerify(firstSnapshot.subAccounts?.first?.consecutiveFailures == nil, "Older gateways may omit current failure streak")

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
        try await verifySubAccountFailures()
    }

    @MainActor private static func verifySubAccountFailures() async throws {
        func payload(failures: Int) throws -> Data {
            let children: [[String: Any]] = (1...5).map { index in
                ["uid": "fixture-\(index)", "nickname": "Child \(index)", "credits": 100,
                 "disabled": false, "manual_disabled": false, "cooling": false,
                 "consecutive_fails": index == 4 ? failures : 0,
                 "last_err": "retained historical error", "err_total": 3]
            }
            // Reproduce the observed contract: healthy includes a child with a
            // nonzero failure streak; last_err remains populated after recovery.
            return try JSONSerialization.data(withJSONObject: ["healthy": 5, "total": 5, "accounts": children])
        }
        let failing = try payload(failures: 2)
        let recovered = try payload(failures: 0)
        let client = WorkBuddyFixtureClient(statusPayloads: [failing, Data(), recovered])
        let repository = InMemoryLocalRepository()
        let credentials = InMemoryCredentialStore()
        let account = AccountConfiguration(displayName: "Gateway state fixture", providerKind: .workbuddy2api,
                                           siteOrigin: URL(string: "https://gateway.example.invalid")!)
        try repository.upsertAccount(account)
        try await credentials.save(ProviderCredential(secret: "fixture-token"), reference: account.credentialReference)
        let adapters = ProviderAdapterRegistry(adapters: [WorkBuddy2APIAdapter(client: client)])
        let store = RelayStore(repository: repository, credentialStore: credentials, adapters: adapters, automaticallyRefresh: false)
        await store.refresh(accountID: account.id)
        let children = store.dashboardAccounts
        try workBuddyVerify(children.count == 5, "All gateway children remain visible")
        let childID = "\(account.id.uuidString):fixture-4"
        guard let failed = children.first(where: { $0.id == childID }) else {
            throw WorkBuddyCheckFailure(description: "Missing failing child")
        }
        try workBuddyVerify(failed.status == .error("连续失败 2 次") && failed.consecutiveFailures == 2,
                           "consecutive_fails must flag the individual account even with healthy=5 and no reason/disabled flag")
        try workBuddyVerify(children.filter { $0.status == .ok }.count == 4, "Historical last_err/err_total cannot mark healthy siblings as failed")
        try workBuddyVerify(store.hasAnyWarning, "Failing child participates in overall warning state")
        try workBuddyVerify(store.accounts.first?.status == .ok, "Successful gateway synchronization is independent from child call failure")
        try workBuddyVerify(store.creditTotal().value == 500, "Operational failure does not discard observed credit balances")
        try workBuddyVerify(store.accountDetail(for: childID)?.account.status == failed.status, "Home and detail share the same failed state")
        let presentation = AccountHealthPresentation(account: failed, health: store.health(for: account.id))
        try workBuddyVerify(presentation.summary == "连续失败 2 次" && presentation.subAccountStatusMessage == "连续失败 2 次",
                           "Home row and detail footer show child failure despite successful gateway refresh")
        try workBuddyVerify(presentation.detail.contains("子账户状态：连续失败 2 次") && presentation.detail.contains("网关同步：最近刷新成功"),
                           "Tooltip/accessibility distinguishes child failure from gateway synchronization")
        var refreshing = store.health(for: account.id)
        refreshing.phase = .refreshing
        try workBuddyVerify(AccountHealthPresentation(account: failed, health: refreshing).summary == presentation.summary,
                           "Refreshing the gateway must not hide a known child failure")

        let snapshot = try repository.snapshot(accountID: account.id)!
        let encoded = try JSONEncoder().encode(snapshot)
        try workBuddyVerify(!String(decoding: encoded, as: UTF8.self).contains("retained historical error"),
                           "Raw upstream last_err must not enter persisted snapshots")
        let persisted = try JSONDecoder().decode(ProviderSnapshot.self, from: encoded)
        try workBuddyVerify(persisted.subAccounts?.first(where: { $0.id == childID })?.consecutiveFailures == 2,
                           "Failure streak survives snapshot serialization")
        let reopened = RelayStore(repository: repository, credentialStore: credentials, adapters: adapters, automaticallyRefresh: false)
        try workBuddyVerify(reopened.accountDetail(for: childID)?.account.status == failed.status, "Reopened store retains failed child state")
        let oldChild = ProviderSubAccountSnapshot(parentAccountID: account.id, externalID: "legacy", displayName: "Legacy", availablePoints: 1)
        let legacy = try JSONDecoder().decode(ProviderSubAccountSnapshot.self, from: JSONEncoder().encode(oldChild))
        try workBuddyVerify(legacy.consecutiveFailures == nil, "Old snapshots without consecutiveFailures remain readable")

        await store.refresh(accountID: account.id)
        try workBuddyVerify(store.accountDetail(for: childID)?.account.consecutiveFailures == 2,
                           "Gateway request failure retains the last known upstream failure streak")
        await store.refresh(accountID: account.id)
        try workBuddyVerify(store.dashboardAccounts.allSatisfy { $0.status == .ok && $0.consecutiveFailures == 0 },
                           "Zero current failure streak clears only after a successful refresh, even with retained last_err")
        try workBuddyVerify(!store.hasAnyWarning, "Recovered children clear overall warning state")
        let invalid = WorkBuddy2APIAdapter(client: WorkBuddyFixtureClient(statusPayloads: [try payload(failures: -1)]))
        do {
            _ = try await invalid.fetchSnapshot(for: account, credential: ProviderCredential(secret: "fixture"),
                                               rate: snapshot.rate, now: Date(), calendar: .current)
            throw WorkBuddyCheckFailure(description: "Negative failure streak was accepted")
        } catch ProviderError.incompatibleResponse {}
        print("PASSED: real-shaped wb2api consecutive_fails, healthy siblings, retained historical errors, shared status presentation, persistence and recovery")
    }
}
