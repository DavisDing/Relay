import Foundation

private actor PreferenceRateAdapter: ProviderAdapter {
    let kind: ProviderKind = .pipio
    let now: Date
    private(set) var calls = 0
    var fails = false
    init(now: Date) { self.now = now }
    func setFailure(_ value: Bool) { fails = value }
    func fetchAccountRate(for account: AccountConfiguration, credential: ProviderCredential) async throws -> AccountRate {
        calls += 1
        if fails { throw ProviderError.transport }
        return AccountRate(accountID: account.id, source: .pipioAccountStatus, nativeCurrency: .cny,
            quotaPerUnit: 500_000, amountMultiplier: 1, fetchedAt: now)
    }
    func validateAccount(_ account: AccountConfiguration, credential: ProviderCredential) async throws {}
    func fetchSnapshot(for account: AccountConfiguration, credential: ProviderCredential, rate: AccountRate,
                       now: Date, calendar: Calendar) async throws -> ProviderSnapshot {
        ProviderSnapshot(accountID: account.id, balance: MoneyValue(amount: 10, currency: .cny),
            todaySpend: nil, monthSpend: nil, requestCount: nil, capabilities: [.balance],
            freshness: .fresh, fetchedAt: now, rate: rate)
    }
}

/// Deliberately completes an in-flight credential write after cancellation.
/// The account service must compensate it before returning to the caller.
private actor PausingFormCredentials: CredentialStore {
    private var values: [String: ProviderCredential] = [:]
    private var shouldPause = false
    private var paused = false
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var pauseObserver: CheckedContinuation<Void, Never>?
    func pauseNextSave() { shouldPause = true; paused = false }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseObserver = $0 }
    }
    func resumeSave() { saveContinuation?.resume(); saveContinuation = nil }
    func count() -> Int { values.count }
    func save(_ credential: ProviderCredential, reference: String) async throws {
        values[reference] = credential
        if shouldPause {
            shouldPause = false
            await withCheckedContinuation { continuation in
                saveContinuation = continuation
                paused = true
                pauseObserver?.resume(); pauseObserver = nil
            }
        }
    }
    func read(reference: String) async throws -> ProviderCredential {
        guard let value = values[reference] else { throw CredentialStoreError.notFound }
        return value
    }
    func delete(reference: String) async throws { values.removeValue(forKey: reference) }
}

@MainActor
enum UnfinishedFeatureChecks {
    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "UnfinishedFeatureChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func run() async throws {
        try projections()
        try compatibility()
        try await rates()
        try await cancellation()
        print("PASSED: full-month overview, stale totals, provider date boundaries, daily selection, token completeness, rate preference compatibility/scheduling and cancelled form compensation")
    }

    private static func projections() throws {
        let iso = ISO8601DateFormatter()
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(secondsFromGMT: -8 * 3600)!
        let now = iso.date(from: "2026-03-31T16:01:00Z")! // April in UTC+8; March locally.
        let old = now.addingTimeInterval(-120)
        let account = AccountConfiguration(displayName: "DeepSeek fixture", providerKind: .deepseek,
            siteOrigin: URL(string: "https://example.invalid")!)
        let rate = AccountRate(accountID: account.id, source: .providerNativeCurrency, nativeCurrency: .cny)
        let snapshot = ProviderSnapshot(accountID: account.id, balance: MoneyValue(amount: 10, currency: .cny),
            todaySpend: MoneyValue(amount: 3, currency: .cny), monthSpend: MoneyValue(amount: 20, currency: .cny),
            requestCount: 4, capabilities: [.balance, .todayUsage, .monthlyUsage], freshness: .fresh, fetchedAt: old, rate: rate)
        let repository = InMemoryLocalRepository()
        try repository.upsertAccount(account)
        try repository.upsertSnapshot(snapshot)
        let store = RelayStore(repository: repository, credentialStore: InMemoryCredentialStore(),
            adapters: .init(adapters: []), calendar: local, automaticallyRefresh: false)
        store.updateTemporalPresentation(at: now)
        try check(store.accountModel(id: account.id)?.todaySpend == nil, "DeepSeek today must reset at UTC+8 midnight")
        try check(store.accountModel(id: account.id)?.monthSpend == nil, "DeepSeek month must reset at UTC+8 month boundary")
        try check(store.todaySpendTotalCNY.value == nil && !store.todaySpendTotalCNY.isComplete, "Cross-calendar today must not enter totals")
        store.updateTemporalPresentation(at: old.addingTimeInterval(601))
        try check(store.balanceTotalCNY.value == nil && !store.balanceTotalCNY.isComplete, "Aged same-currency balances cannot enter totals")
        try check(store.accountModel(id: account.id)?.balance == 10, "Detail retains cached balance after expiry")

        let localMidnight = iso.date(from: "2026-04-01T08:01:00Z")!
        let sameProviderDay = ProviderSnapshot(accountID: account.id, balance: MoneyValue(amount: 10, currency: .cny),
            todaySpend: MoneyValue(amount: 3, currency: .cny), monthSpend: nil, requestCount: nil,
            capabilities: [.balance, .todayUsage], freshness: .fresh,
            fetchedAt: localMidnight.addingTimeInterval(-120), rate: rate)
        try repository.upsertSnapshot(sameProviderDay)
        store.updateTemporalPresentation(at: localMidnight)
        try check(store.todaySpendTotalCNY.value?.amount == 3 && store.todaySpendTotal(forAccountIDs: [account.id]).isComplete,
                  "Local midnight must not discard still-current DeepSeek data")

        let calendar = DeepSeekUsageService.historyCalendar
        let end = iso.date(from: "2026-03-31T04:00:00Z")!
        let start = iso.date(from: "2026-01-31T16:00:00Z")!
        var date = start
        var records: [DailyUsageRecord] = []
        while date <= end {
            let record = DailyUsageRecord(accountID: account.id, day: date, spend: MoneyValue(amount: 1, currency: .cny))
            records.append(record)
            try repository.upsertDailyUsage(record)
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
        store.updateTemporalPresentation(at: end)
        let row = store.consumptionOverview().first!
        try check(row.month.knownDays == 31 && row.previousMonth.knownDays == 28, "Overview must load both full natural months, beyond 30 records")
        try check(row.changePercent == nil, "Unequal comparison periods must stay incomparable")
        let model = ModelUsageSummary(modelName: "selected-day", tokenCount: 12, requestCount: 1, spend: nil)
        let selectedDay = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: end))!
        let daily = DailyUsageRecord(accountID: account.id, day: selectedDay, spend: MoneyValue(amount: 1, currency: .cny), modelUsages: [model])
        records = records.filter { $0.id != daily.id } + [daily]
        let points = DailyModelUsageService.trendPoints(accountID: account.id, provider: .deepseek, records: records,
            currency: .cny, now: end, calendar: local)
        let selection = points.first { $0.id == daily.id }!
        try check(points.count == 7 && selection.day == selectedDay, "Trend carries the exact provider date rather than a display label")
        try check(DailyModelUsageService.models(accountID: account.id, provider: .deepseek, day: selection.day!, records: records, snapshot: nil) == [model], "Selecting a point resolves that day's models")
        let absentDay = calendar.startOfDay(for: end)
        try check(DailyModelUsageService.models(accountID: account.id, provider: .deepseek, day: absentDay, records: records, snapshot: snapshot) == nil, "Missing historical models must not use another day/month")
        try check(DailyModelUsageService.tokenCount(nil) == nil && DailyModelUsageService.tokenCount([]) == 0, "Unknown tokens and known empty list differ")
        let missing = ModelUsageSummary(modelName: "missing", tokenCount: nil, requestCount: nil, spend: nil)
        try check(DailyModelUsageService.tokenCount([model, missing]) == nil, "Partial token metrics cannot claim a total")
        let max = ModelUsageSummary(modelName: "max", tokenCount: .max, requestCount: nil, spend: nil)
        try check(DailyModelUsageService.tokenCount([model, max]) == nil, "Token sum overflow must remain unknown")
    }

    private static func compatibility() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let settings = RelaySettings(rateRefreshInterval: .monthly)
        var json = try JSONSerialization.jsonObject(with: encoder.encode(settings)) as! [String: Any]
        json.removeValue(forKey: "rateRefreshInterval")
        let legacy = try decoder.decode(RelaySettings.self, from: JSONSerialization.data(withJSONObject: json))
        try check(legacy.rateRefreshInterval == .weekly, "Old settings default to weekly")
        let archive = RelaySyncData(accounts: [], snapshots: [], dailyUsage: [], settings: settings)
        let preview = try DataTransferService.previewConfiguration(DataTransferService.exportConfiguration(archive), existingAccountIDs: [])
        try check(preview.archive.settings.rateRefreshInterval == .monthly, "Rate choice survives configuration export/import whitelist")
        try check(try DataTransferService.decodeBackup(DataTransferService.exportBackup(archive)).settings == settings, "Backup preserves the new preference")
    }

    private static func rates() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-03-31T12:00:00Z")!
        let adapter = PreferenceRateAdapter(now: now), service = RateService()
        let account = AccountConfiguration(displayName: "rate", providerKind: .pipio, siteOrigin: URL(string: "https://example.invalid")!)
        let credential = ProviderCredential(secret: "fixture-only", pipioUserID: "1")
        let previous = AccountRate(accountID: account.id, source: .pipioAccountStatus, nativeCurrency: .cny,
            quotaPerUnit: 500_000, amountMultiplier: 1, fetchedAt: now.addingTimeInterval(-2 * 86_400))
        let weekly = try await service.resolve(account: account, credential: credential, adapter: adapter, persistedRate: previous,
            forceRefresh: false, refreshInterval: .weekly, calendar: calendar, now: now)
        try check(weekly.rate.fetchedAt == previous.fetchedAt, "Weekly setting reuses a two-day-old value")
        let daily = try await service.resolve(account: account, credential: credential, adapter: adapter, persistedRate: previous,
            forceRefresh: false, refreshInterval: .daily, calendar: calendar, now: now)
        let dailyCalls = await adapter.calls
        try check(dailyCalls == 1 && daily.rate.expiresAt == now.addingTimeInterval(86_400), "Shortening the interval refreshes immediately and persists the new due date")
        let monthly = try await service.resolve(account: account, credential: credential, adapter: adapter, persistedRate: nil,
            forceRefresh: false, refreshInterval: .monthly, calendar: calendar, now: now)
        try check(monthly.rate.expiresAt == calendar.date(byAdding: .month, value: 1, to: now), "Monthly is a calendar month, including short months")
        let manual = try await service.resolve(account: account, credential: credential, adapter: adapter, persistedRate: nil,
            forceRefresh: false, refreshInterval: .manual, calendar: calendar, now: now.addingTimeInterval(90 * 86_400))
        let manualCalls = await adapter.calls
        try check(manualCalls == 1 && manual.rate.expiresAt == nil, "Manual mode never automatically refreshes an existing value")
        _ = try await service.resolve(account: account, credential: credential, adapter: adapter, persistedRate: nil,
            forceRefresh: true, refreshInterval: .manual, now: now)
        let forcedCalls = await adapter.calls
        try check(forcedCalls == 2, "Explicit refresh works in manual mode")
        await adapter.setFailure(true)
        let failure = try await service.resolve(account: account, credential: credential, adapter: adapter, persistedRate: nil,
            forceRefresh: false, refreshInterval: .daily, now: now.addingTimeInterval(2 * 86_400))
        try check(failure.isStale && failure.rate.fetchedAt == now, "Failed refresh retains the last successful value and marks it stale")
        let restarted = RateService()
        let retainedFailure = try await restarted.resolve(account: account, credential: credential, adapter: adapter,
            persistedRate: failure.rate, persistedRateIsStale: true, forceRefresh: false, refreshInterval: .manual, now: now)
        try check(retainedFailure.isStale, "Manual mode must not clear a persisted failed-rate state after restart")
    }

    private static func cancellation() async throws {
        let repository = InMemoryLocalRepository(), credentials = PausingFormCredentials()
        let service = AccountService(repository: repository, credentialStore: credentials,
            adapters: .init(adapters: [PreferenceRateAdapter(now: Date())]))
        let secret = ProviderCredential(secret: "fixture-only", pipioUserID: "1")
        let draft = AccountDraft(displayName: "cancelled", providerKind: .pipio, baseURL: "https://example.invalid", credential: secret)
        await credentials.pauseNextSave()
        let add = Task { @MainActor in try await service.addAccount(draft) }
        await credentials.waitUntilPaused()
        add.cancel()
        await credentials.resumeSave()
        do { _ = try await add.value; throw NSError(domain: "Cancelled add committed", code: 1) }
        catch is CancellationError {}
        let count = await credentials.count()
        try check(try repository.fetchAccounts().isEmpty && count == 0, "Cancelled add compensates its in-flight credential and saves no account")

        let account = try await service.addAccount(draft)
        await credentials.pauseNextSave()
        let edit = Task { @MainActor in
            try await service.updateAccount(accountID: account.id, displayName: "changed", lowBalanceThreshold: 2,
                replacementCredential: ProviderCredential(secret: "replacement-fixture", pipioUserID: "1"),
                preferences: .set(monthlyBudget: MoneyValue(amount: 50, currency: .cny), groupName: "changed", isPinned: true))
        }
        await credentials.waitUntilPaused()
        edit.cancel()
        await credentials.resumeSave()
        do { try await edit.value; throw NSError(domain: "Cancelled edit committed", code: 1) }
        catch is CancellationError {}
        let preserved = try await credentials.read(reference: account.credentialReference)
        try check(try repository.account(id: account.id) == account && preserved == secret, "Cancelled edit rolls back the credential and preserves all original preferences")
    }
}
