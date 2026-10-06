import Foundation

private struct DetailRefreshFailure: Error { let message: String }

/// Synthetic provider responses; no real credentials or network requests.
private actor DetailRefreshAdapter: ProviderAdapter {
    let kind: ProviderKind
    private var responses: [Result<ProviderSnapshot, ProviderError>]

    init(kind: ProviderKind, responses: [Result<ProviderSnapshot, ProviderError>]) {
        self.kind = kind
        self.responses = responses
    }

    func validateAccount(_ account: AccountConfiguration, credential: ProviderCredential) async throws {}
    func fetchAccountRate(for account: AccountConfiguration, credential: ProviderCredential) async throws -> AccountRate {
        AccountRate(accountID: account.id, source: .providerNativeCurrency, nativeCurrency: .cny)
    }
    func fetchSnapshot(for account: AccountConfiguration, credential: ProviderCredential,
                       rate: AccountRate, now: Date, calendar: Calendar) async throws -> ProviderSnapshot {
        guard !responses.isEmpty else { throw DetailRefreshFailure(message: "Unexpected provider request") }
        return try responses.removeFirst().get()
    }
}

enum AccountDetailRefreshChecks {
    @MainActor private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw DetailRefreshFailure(message: message) }
    }

    @MainActor private static func requireDetail(_ store: RelayStore, _ id: String) throws -> AccountDetailData {
        guard let data = store.accountDetail(for: id) else { throw DetailRefreshFailure(message: "Missing detail: " + id) }
        return data
    }

    @MainActor static func run() async throws {
        for kind in [ProviderKind.pipio, .deepseek] { try await monetaryAccount(kind) }
        try await gatewayAccount()
        print("PASSED: live detail projections, successful/failed refresh, recovery, unknown metrics, DeepSeek usage and gateway children")
    }

    @MainActor private static func monetaryAccount(_ kind: ProviderKind) async throws {
        let repository = InMemoryLocalRepository()
        let credentials = InMemoryCredentialStore()
        let account = AccountConfiguration(displayName: "Detail fixture", providerKind: kind,
                                           siteOrigin: URL(string: "https://example.invalid")!)
        try repository.upsertAccount(account)
        try await credentials.save(ProviderCredential(secret: "fixture-only"), reference: account.credentialReference)
        let now = Date()
        let oldDate = now.addingTimeInterval(-120)
        let rate = AccountRate(accountID: account.id, source: .providerNativeCurrency, nativeCurrency: .cny)
        func snapshot(balance: Decimal?, spend: Decimal?, models: [ModelUsageSummary]?, at date: Date) -> ProviderSnapshot {
            ProviderSnapshot(accountID: account.id, balance: balance.map { MoneyValue(amount: $0, currency: .cny) },
                             todaySpend: spend.map { MoneyValue(amount: $0, currency: .cny) },
                             monthSpend: spend.map { MoneyValue(amount: $0 * 10, currency: .cny) },
                             requestCount: nil, modelUsages: models,
                             capabilities: models == nil ? [.balance] : [.balance, .monthlyUsage, .modelUsage],
                             freshness: .fresh, fetchedAt: date, rate: rate)
        }
        func model(_ name: String, _ cost: Decimal, _ tokens: Int64) -> [ModelUsageSummary] {
            [ModelUsageSummary(modelName: name, tokenCount: tokens, requestCount: nil,
                               spend: MoneyValue(amount: cost, currency: .cny))]
        }
        let old = snapshot(balance: 100, spend: 1, models: model("old-model", 1, 100), at: oldDate)
        let fresh = snapshot(balance: 80, spend: 3, models: model("new-model", 3, 300), at: now)
        let unknown = snapshot(balance: nil, spend: nil, models: nil, at: now.addingTimeInterval(1))
        try repository.upsertSnapshot(old)
        let historyCalendar = kind == .deepseek ? DeepSeekUsageService.historyCalendar : Calendar.current
        try repository.upsertDailyUsage(DailyUsageRecord(accountID: account.id,
            day: historyCalendar.startOfDay(for: now), spend: old.todaySpend))
        let adapter = DetailRefreshAdapter(kind: kind, responses: [.success(fresh), .failure(.unauthorized), .success(unknown)])
        let store = RelayStore(repository: repository, credentialStore: credentials,
                               adapters: ProviderAdapterRegistry(adapters: [adapter]), automaticallyRefresh: false)
        let id = account.id.uuidString
        let openingData = try requireDetail(store, id)
        try check(openingData.account.balance == 100 && openingData.modelUsages.first?.modelName == "old-model", "Opening detail baseline")

        // Same entry point called by the automatic loop, without waiting five minutes.
        await store.refreshAll()
        let updated = try requireDetail(store, id)
        try check(updated.account.balance == 80 && updated.account.todaySpend == 3 && updated.account.monthSpend == 30, "Refresh monetary values")
        try check(updated.account.lastUpdated == now, "Refresh timestamp")
        try check(updated.modelUsages.first?.modelName == "new-model" && updated.modelUsages.first?.tokenCount == 300, "Refresh models and tokens")
        try check(updated.spendPoints.last?.amount == 3, "Refresh trend history")
        try check(updated.spendPoints.last?.id == openingData.spendPoints.last?.id, "Stable trend identity")
        if kind == .deepseek {
            try check(updated.deepSeekUsageReport?.fetchedAt == now && updated.deepSeekUsageReport?.models?.first?.tokenCount == 300,
                      "Refresh DeepSeek report")
        }
        await store.refreshAll()
        let failed = try requireDetail(store, id)
        try check(failed.account.balance == 80 && failed.account.lastUpdated == now && failed.spendPoints.last?.amount == 3,
                  "Failure preserves last successful data")
        guard case .error = failed.account.status else { throw DetailRefreshFailure(message: "Failure status must reach detail") }

        await store.refresh(accountID: account.id)
        let recovered = try requireDetail(store, id)
        try check(recovered.account.balance == nil && recovered.account.todaySpend == nil && recovered.modelUsages.isEmpty,
                  "Missing metrics clear previous values without fabricating zero")
        try check(recovered.spendPoints.isEmpty, "Unknown daily spend removes obsolete point")
        guard case .ok = recovered.account.status else { throw DetailRefreshFailure(message: "Successful refresh clears error") }
        if kind == .deepseek { try check(recovered.deepSeekUsageReport?.coverage == .unsupported, "Balance-only DeepSeek clears old usage") }
        await store.deleteAccount(id: account.id)
        try check(store.accountDetail(for: id) == nil, "Deleted account must not retain opening snapshot")
    }

    @MainActor private static func gatewayAccount() async throws {
        let repository = InMemoryLocalRepository()
        let credentials = InMemoryCredentialStore()
        let parent = AccountConfiguration(displayName: "Gateway fixture", providerKind: .workbuddy2api,
                                          siteOrigin: URL(string: "https://gateway.example.invalid")!)
        try repository.upsertAccount(parent)
        try await credentials.save(ProviderCredential(secret: "fixture-only"), reference: parent.credentialReference)
        let now = Date()
        let oldChild = ProviderSubAccountSnapshot(parentAccountID: parent.id, externalID: "uid-1", displayName: "Old child",
                                                  availablePoints: 100, fetchedAt: now.addingTimeInterval(-120))
        let newChild = ProviderSubAccountSnapshot(parentAccountID: parent.id, externalID: "uid-1", displayName: "New child",
                                                  availablePoints: 125, disabled: true, manualDisabled: true, cooling: true, fetchedAt: now)
        let rate = AccountRate(accountID: parent.id, source: .providerNativeCurrency, nativeCurrency: .cny)
        func snapshot(_ children: [ProviderSubAccountSnapshot], credit: Decimal) -> ProviderSnapshot {
            ProviderSnapshot(accountID: parent.id, balance: nil, todaySpend: nil, monthSpend: nil, requestCount: nil,
                             modelUsages: [ModelUsageSummary(modelName: "gateway-model", tokenCount: 600, requestCount: nil,
                                                             spend: MoneyValue(amount: credit, currency: .cny))],
                             capabilities: [.creditBalance, .modelUsage], freshness: .fresh, fetchedAt: now, rate: rate,
                             subAccounts: children,
                             workBuddyStats: WorkBuddyStatsSnapshot(since: now.addingTimeInterval(-3600),
                                                                   total: WorkBuddyStatsCounter(credit: credit)))
        }
        try repository.upsertSnapshot(snapshot([oldChild], credit: 1))
        let adapter = DetailRefreshAdapter(kind: .workbuddy2api, responses: [.success(snapshot([newChild], credit: 3)),
                                                                          .failure(.unauthorized), .success(snapshot([], credit: 3))])
        let store = RelayStore(repository: repository, credentialStore: credentials,
                               adapters: ProviderAdapterRegistry(adapters: [adapter]), automaticallyRefresh: false)
        try check(try requireDetail(store, oldChild.id).account.availablePoints == 100, "Opening gateway child")
        await store.refreshAll()
        let updated = try requireDetail(store, oldChild.id)
        try check(updated.account.availablePoints == 125 && updated.account.name == "New child", "Resolve child by non-UUID ID")
        try check(updated.account.disabled && updated.account.manualDisabled && updated.account.cooling && updated.account.lastUpdated == now,
                  "Refresh gateway status and timestamp")
        try check(updated.modelUsages.first?.cost == 3 && updated.spendPoints.last?.amount == 2, "Gateway models and history come from parent")
        await store.refreshAll()
        let failed = try requireDetail(store, oldChild.id)
        try check(failed.account.availablePoints == 125, "Gateway failure retains credits")
        guard case .error = failed.account.status else { throw DetailRefreshFailure(message: "Gateway error reaches child detail") }
        await store.refreshAll()
        try check(store.accountDetail(for: oldChild.id) == nil, "Removed gateway child must not retain stale data")
    }
}
