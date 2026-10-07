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

/// Inject failures after setup, including after some account reads succeeded.
@MainActor
final class DetailFailureRepository: LocalRepository {
    let base = InMemoryLocalRepository()
    var failAccountReads = false
    var failSettingsReads = false
    var failSnapshotID: UUID?
    var failHistoryID: UUID?

    func fetchAccounts() throws -> [AccountConfiguration] {
        if failAccountReads { throw LocalRepositoryError.unavailable }
        return try base.fetchAccounts()
    }
    func account(id: UUID) throws -> AccountConfiguration? { try base.account(id: id) }
    func upsertAccount(_ account: AccountConfiguration) throws { try base.upsertAccount(account) }
    func deleteAccount(id: UUID) throws { try base.deleteAccount(id: id) }
    func snapshot(accountID: UUID) throws -> ProviderSnapshot? {
        if failSnapshotID == accountID { throw LocalRepositoryError.unavailable }
        return try base.snapshot(accountID: accountID)
    }
    func upsertSnapshot(_ snapshot: ProviderSnapshot) throws { try base.upsertSnapshot(snapshot) }
    func commitRefresh(_ snapshot: ProviderSnapshot, dailyUsage: DailyUsageRecord?) throws {
        try base.commitRefresh(snapshot, dailyUsage: dailyUsage)
    }
    func dailyUsage(accountID: UUID, limit: Int?) throws -> [DailyUsageRecord] {
        if failHistoryID == accountID { throw LocalRepositoryError.unavailable }
        return try base.dailyUsage(accountID: accountID, limit: limit)
    }
    func upsertDailyUsage(_ record: DailyUsageRecord) throws { try base.upsertDailyUsage(record) }
    func settings() throws -> RelaySettings {
        if failSettingsReads { throw LocalRepositoryError.unavailable }
        return try base.settings()
    }
    func updateSettings(_ settings: RelaySettings) throws { try base.updateSettings(settings) }
    func syncData() throws -> RelaySyncData { try base.syncData() }
    func mergeSyncData(_ data: RelaySyncData) throws { try base.mergeSyncData(data) }
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
        try repositoryReadFailures()
        print("PASSED: live detail projections, successful/failed refresh, recovery, unknown metrics, DeepSeek usage, hidden/disabled gateway children and repository read failure recovery")
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
                                                                          .failure(.unauthorized), .success(snapshot([newChild], credit: 4)),
                                                                          .success(snapshot([], credit: 4))])
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
        store.setHidden(accountID: parent.id, hidden: true)
        try check(store.dashboardAccounts.isEmpty, "Hidden gateway stays excluded from home")
        try check(try requireDetail(store, oldChild.id).account.availablePoints == 125, "Hiding gateway retains child detail")
        await store.refresh(accountID: parent.id)
        try check(try requireDetail(store, oldChild.id).modelUsages.first?.cost == 4, "Hidden gateway detail still receives refreshes")
        store.setEnabled(accountID: parent.id, enabled: false)
        try check(store.snapshots.isEmpty, "Disabled snapshots stay excluded from totals")
        let disabled = try requireDetail(store, oldChild.id)
        try check(!disabled.account.isEnabled && disabled.account.availablePoints == 125 && disabled.modelUsages.first?.cost == 4,
                  "Disabled gateway retains full cached child detail")
        guard case .warning("网关已停用") = disabled.account.status else {
            throw DetailRefreshFailure(message: "Disabled gateway status reaches child")
        }
        store.setEnabled(accountID: parent.id, enabled: true)
        await store.refreshAll()
        guard case .removed = store.accountDetailState(for: oldChild.id) else {
            throw DetailRefreshFailure(message: "Removed gateway child must not retain stale data")
        }
    }

    @MainActor private static func repositoryReadFailures() throws {
        let repository = DetailFailureRepository()
        let first = AccountConfiguration(displayName: "First detail", providerKind: .deepseek,
                                         siteOrigin: URL(string: "https://fixture.invalid")!, sortOrder: 0)
        var second = AccountConfiguration(displayName: "Second detail", providerKind: .pipio,
                                          siteOrigin: URL(string: "https://fixture.invalid")!, sortOrder: 1)
        let now = Date()
        for account in [first, second] {
            try repository.upsertAccount(account)
            let snapshot = ProviderSnapshot(
                accountID: account.id, balance: MoneyValue(amount: 100, currency: .cny),
                todaySpend: MoneyValue(amount: 1, currency: .cny), monthSpend: nil, requestCount: nil,
                capabilities: [.balance, .monthlyUsage], freshness: .fresh, fetchedAt: now,
                rate: AccountRate(accountID: account.id, source: .providerNativeCurrency, nativeCurrency: .cny)
            )
            try repository.upsertSnapshot(snapshot)
            try repository.upsertDailyUsage(DailyUsageRecord(accountID: account.id, day: Calendar.current.startOfDay(for: now), spend: snapshot.todaySpend))
        }
        let store = RelayStore(repository: repository, credentialStore: InMemoryCredentialStore(),
                               adapters: ProviderAdapterRegistry(adapters: []), automaticallyRefresh: false)
        let id = first.id.uuidString
        let before = try requireDetail(store, id)
        // A deletion read must not be published halfway through a failed reload.
        try repository.deleteAccount(id: first.id)
        second.displayName = "Changed second"
        try repository.upsertAccount(second)
        for failure in 0..<4 {
            repository.failSettingsReads = failure == 0
            repository.failAccountReads = failure == 1
            repository.failSnapshotID = failure == 2 ? second.id : nil
            repository.failHistoryID = failure == 3 ? second.id : nil
            store.updateTemporalPresentation(at: now)
            guard case .unavailable(let cached?, let message) = store.accountDetailState(for: id) else {
                throw DetailRefreshFailure(message: "Read failure must not close the cached detail")
            }
            try check(!message.isEmpty && cached.account.balance == before.account.balance && cached.spendPoints.first?.amount == 1,
                      "Read failure retains all last successful values with visible error")
            try check(cached.deepSeekUsageReport?.daily?.count == before.deepSeekUsageReport?.daily?.count,
                      "Read failure retains cached DeepSeek history")
            try check(store.accounts.count == 2 && store.accounts[1].name == "Second detail", "Failed reload publishes no partial account changes")
            try check(store.snapshots.count == 2 && store.repositoryErrorMessage != nil, "Failed reload preserves snapshots and exposes error")
        }
        repository.failSettingsReads = false
        repository.failAccountReads = false
        repository.failSnapshotID = nil
        repository.failHistoryID = nil
        store.updateTemporalPresentation(at: now)
        guard case .removed = store.accountDetailState(for: id) else {
            throw DetailRefreshFailure(message: "Successful read confirms actual deletion")
        }
        try check(store.repositoryErrorMessage == nil && store.globalErrorMessage == nil, "Recovery clears repository error")
        try check(store.accounts.count == 1 && store.accounts[0].name == "Changed second", "Recovery publishes the new complete state")

        repository.failAccountReads = true
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        store.updateTemporalPresentation(at: tomorrow)
        let expired = try requireDetail(store, second.id.uuidString)
        try check(expired.account.todaySpend == nil && expired.account.balance == 100 && expired.spendPoints.first?.amount == 1,
                  "Read failure across midnight expires today but preserves balance and historical trend")
        try check(store.todaySpendTotalCNY.value == nil, "Storage failure must not present yesterday's amount as today's total")
        let unavailable = RelayStore(repository: repository, credentialStore: InMemoryCredentialStore(),
                                    adapters: ProviderAdapterRegistry(adapters: []), automaticallyRefresh: false)
        guard case .unavailable(nil, _) = unavailable.accountDetailState(for: second.id.uuidString) else {
            throw DetailRefreshFailure(message: "Initial read failure is unavailable, never a confirmed deletion")
        }
        repository.failAccountReads = false
        unavailable.updateTemporalPresentation(at: now)
        guard case .available = unavailable.accountDetailState(for: second.id.uuidString) else {
            throw DetailRefreshFailure(message: "Initial failure remains recoverable")
        }
    }

}
