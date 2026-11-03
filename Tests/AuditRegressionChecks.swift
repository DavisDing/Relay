import Foundation

private actor AuditRateAdapter: ProviderAdapter {
    let kind: ProviderKind = .deepseek
    let fetchedAt: Date
    var failRate = true
    var rateCalls = 0
    init(fetchedAt: Date) { self.fetchedAt = fetchedAt }
    func fail() { failRate = true }
    func recover() { failRate = false }
    func validateAccount(_ account: AccountConfiguration, credential: ProviderCredential) async throws {}
    func fetchAccountRate(for account: AccountConfiguration, credential: ProviderCredential) async throws -> AccountRate {
        rateCalls += 1
        if failRate { throw ProviderError.transport }
        return AccountRate(accountID: account.id, source: .providerNativeCurrency, nativeCurrency: .usd,
                           conversionToCNY: 7, fetchedAt: fetchedAt)
    }
    func fetchSnapshot(for account: AccountConfiguration, credential: ProviderCredential, rate: AccountRate,
                       now: Date, calendar: Calendar) async throws -> ProviderSnapshot {
        ProviderSnapshot(accountID: account.id, balance: MoneyValue(amount: 10, currency: .usd),
            todaySpend: MoneyValue(amount: 2, currency: .usd), monthSpend: nil, requestCount: nil,
            capabilities: [.balance, .todayUsage], freshness: .fresh, fetchedAt: now, rate: rate)
    }
}

@MainActor
enum AuditRegressionChecks {
    private static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw NSError(domain: "AuditRegressionChecks", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func run() async throws {
        let now = Date(timeIntervalSince1970: 1_793_500_000)
        let calendar = DeepSeekUsageService.historyCalendar
        let repo = InMemoryLocalRepository(), credentials = InMemoryCredentialStore()
        let account = AccountConfiguration(displayName: "audit fixture", providerKind: .deepseek,
                                           siteOrigin: URL(string: "https://example.invalid")!)
        let oldRate = AccountRate(accountID: account.id, source: .providerNativeCurrency, nativeCurrency: .usd,
            conversionToCNY: 7, fetchedAt: now.addingTimeInterval(-2 * 86_400),
            expiresAt: now.addingTimeInterval(20 * 86_400))
        let old = ProviderSnapshot(accountID: account.id, balance: nil, todaySpend: nil, monthSpend: nil,
            requestCount: nil, capabilities: [], freshness: .stale,
            fetchedAt: now.addingTimeInterval(-1000), rate: oldRate)
        try repo.upsertAccount(account)
        try repo.upsertSnapshot(old)
        try repo.updateSettings(RelaySettings(rateRefreshInterval: .daily))
        try await credentials.save(ProviderCredential(secret: "offline fixture"), reference: account.credentialReference)
        let adapter = AuditRateAdapter(fetchedAt: now)
        let coordinator = RefreshCoordinator(repository: repo, credentialStore: credentials,
            adapters: ProviderAdapterRegistry(adapters: [adapter]), calendar: calendar,
            maxRetryCount: 0, clock: RefreshClock(now: { now }))
        let first = await coordinator.refresh(accountID: account.id)
        try check(first.isSuccess && first.snapshot?.freshness == .fresh,
                  "A failed FX fetch must not stale a successful native response")
        try check(try repo.snapshot(accountID: account.id)?.rate == oldRate,
                  "Month-to-day + failure must preserve the original rate and its validity")
        let store = RelayStore(repository: repo, credentialStore: credentials,
            adapters: ProviderAdapterRegistry(adapters: []), calendar: calendar, automaticallyRefresh: false)
        store.updateTemporalPresentation(at: now)
        try check(store.balanceTotalCNY.isComplete && store.balanceTotalCNY.value?.amount == 70 &&
                  store.todaySpendTotalCNY.isComplete && store.todaySpendTotalCNY.value?.amount == 14,
                  "Shortened schedule + failed fetch must retain both usable cross-currency totals")

        try repo.updateSettings(RelaySettings(rateRefreshInterval: .manual, baseCurrency: .usd))
        let second = await coordinator.refresh(accountID: account.id)
        let calls = await adapter.rateCalls
        try check(second.snapshot?.freshness == .fresh && calls == 1,
                  "Manual mode must refresh native data without retrying FX or poisoning its freshness")
        store.updateTemporalPresentation(at: now)
        try check(store.balanceTotalCNY.value?.amount == 10 && store.todaySpendTotalCNY.value?.amount == 2,
                  "Native-currency store totals survive a previous rate failure in manual mode")

        let expired = AccountRate(accountID: account.id, source: .providerNativeCurrency, nativeCurrency: .usd,
            conversionToCNY: 7, fetchedAt: now.addingTimeInterval(-30 * 86_400), expiresAt: now.addingTimeInterval(-1))
        let service = RateService()
        let retained = try await service.resolve(account: account, credential: .init(secret: "fixture"),
            adapter: adapter, persistedRate: expired, forceRefresh: false, refreshInterval: .manual, now: now)
        try check(retained.rate == expired && retained.isStale, "Manual must not erase an expired deadline")
        let snapshot = try await adapter.fetchSnapshot(for: account, credential: .init(secret: "fixture"),
            rate: retained.rate, now: now, calendar: calendar)
        try check(DashboardAggregator.balanceTotal(snapshots: [snapshot], targetCurrency: .usd, now: now).isComplete,
                  "Expired FX must not exclude native amounts")
        try check(!DashboardAggregator.balanceTotal(snapshots: [snapshot], targetCurrency: .cny, now: now).isComplete,
                  "Expired FX must still reject cross-currency totals")
        try check(DashboardAggregator.balanceTotal(snapshots: [snapshot], targetCurrency: .cny, now: now,
            manualUSDToCNY: [account.id: 6]).value?.amount == 60, "Manual override remains usable with expired provider FX")
        let negative = ProviderSnapshot(accountID: account.id, balance: MoneyValue(amount: Decimal(string: "-12.34")!, currency: .usd),
            todaySpend: MoneyValue(amount: Decimal(string: "-12.34")!, currency: .usd), monthSpend: nil,
            requestCount: nil, capabilities: [.balance, .todayUsage], freshness: .fresh, fetchedAt: now,
            rate: AccountRate(accountID: account.id, source: .providerNativeCurrency, nativeCurrency: .usd))
        let negativeTotal = DashboardAggregator.balanceTotal(snapshots: [negative], targetCurrency: .usd, now: now)
        try check(negativeTotal.value == nil && !negativeTotal.isComplete && negativeTotal.excludedAccountIDs == [account.id],
                  "Live totals reject negative values with the same incomplete semantics as historical totals")
        try check(DashboardAggregator.historicalSpendTotal(values: [account.id: negative.todaySpend!], snapshots: [negative],
            expectedAccountIDs: [account.id], targetCurrency: .usd, now: now) == nil,
                  "Historical trends reject negative spend rather than drawing it")
        let legacy = AccountRate(accountID: account.id, source: .providerNativeCurrency, nativeCurrency: .usd,
            conversionToCNY: 7, fetchedAt: expired.fetchedAt)
        try check(legacy.isExpired(at: now), "Legacy nil deadlines cannot grant unlimited FX validity")
        await adapter.recover()
        let recovered = try await service.resolve(account: account, credential: .init(secret: "fixture"),
            adapter: adapter, persistedRate: nil, forceRefresh: true, refreshInterval: .manual, now: now)
        try check(!recovered.isStale && recovered.rate.expiresAt != nil, "Explicit manual refresh recovers and retains finite validity")

        let retryService = RateService()
        await adapter.fail()
        let failedAgain = try await retryService.resolve(account: account, credential: .init(secret: "fixture"),
            adapter: adapter, persistedRate: expired, forceRefresh: true, refreshInterval: .manual, now: now)
        try check(failedAgain.refreshFailed, "Manual failed-rate refresh records a retryable failure")
        await adapter.recover()
        let recoveredAgain = try await retryService.resolve(account: account, credential: .init(secret: "fixture"),
            adapter: adapter, persistedRate: expired, forceRefresh: true, refreshInterval: .manual, now: now)
        let afterRecovery = try await retryService.resolve(account: account, credential: .init(secret: "fixture"),
            adapter: adapter, persistedRate: nil, forceRefresh: false, refreshInterval: .manual, now: now)
        try check(!recoveredAgain.refreshFailed && !afterRecovery.refreshFailed,
                  "A successful explicit refresh clears the manual-mode failure state")

        try invalidSettings()
        try closeHandler()
        try historyProjection()
        print("PASSED: audit rate-failure/store totals, schedule/validity isolation, manual expiry/recovery, hostile JSON intervals and close/termination decisions")
    }

    private static func invalidSettings() throws {
        let valid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RelaySettings())) as! [String: Any]
        for interval in [Int.min, -1, 0, 59, 86_401, Int.max] {
            var json = valid
            json["refreshIntervalSeconds"] = interval
            let bytes = try JSONSerialization.data(withJSONObject: json)
            do {
                _ = try JSONDecoder().decode(RelaySettings.self, from: bytes)
                throw NSError(domain: "AuditRegressionChecks", code: 2)
            } catch DecodingError.dataCorrupted { }
        }
        var settings = RelaySettings()
        settings.refreshIntervalSeconds = Int.max
        try check(settings.snapshotMaximumAge.isFinite && settings.refreshSleepNanoseconds == 86_400_000_000_000,
                  "Mutable invalid settings must not overflow either age or sleep calculations")
        let validArchive = RelaySyncData(accounts: [], snapshots: [], dailyUsage: [], settings: RelaySettings())
        let invalid = RelaySyncData(accounts: [], snapshots: [], dailyUsage: [], settings: settings)
        do {
            _ = try SyncMerge.merge(validArchive, invalid)
            throw NSError(domain: "AuditRegressionChecks", code: 3)
        } catch LocalRepositoryError.corruptData { }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-bad-refresh-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let damagedURL = root.appendingPathComponent("invalid.json")
        try JSONEncoder().encode(invalid).write(to: damagedURL)
        do {
            _ = try FileLocalRepository(fileURL: damagedURL)
            throw NSError(domain: "AuditRegressionChecks", code: 4)
        } catch LocalRepositoryError.corruptData { }
    }

    private static func closeHandler() throws {
        var discard = false, cancelled = false, prompts = 0
        let handler = RelayPageCloseHandler(confirmDiscard: { _ in prompts += 1; return discard })
        handler.prepareToClose = {
            guard handler.confirmDiscard("fixture") else { return false }
            cancelled = true
            return true
        }
        try check(!handler.requestClose() && !cancelled, "Continuing editing preserves the form operation")
        try check(!handler.requestTermination() && !cancelled, "Quit uses the same form protection")
        discard = true
        try check(handler.requestClose() && cancelled && prompts == 3, "Explicit discard allows cancellation and close")
        handler.prepareToClose = { false }
        handler.prepareToTerminate = { handler.confirmDiscard("save failed") }
        try check(!handler.requestClose() && handler.requestTermination(), "A failed save can block close while allowing explicit discard on quit")
        handler.prepareToClose = { handler.requestClose() }
        try check(!handler.requestClose(), "Nested native close cannot bypass the pending decision")
        handler.prepareToClose = nil
        handler.prepareToTerminate = nil
    }

    private static func historyProjection() throws {
        let repository = DetailFailureRepository()
        let account = AccountConfiguration(displayName: "history order", providerKind: .pipio,
                                           siteOrigin: URL(string: "https://example.invalid")!)
        try repository.upsertAccount(account)
        let today = Calendar.current.startOfDay(for: Date())
        for offset in 0..<3 {
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: today)!
            try repository.upsertDailyUsage(DailyUsageRecord(accountID: account.id, day: day,
                spend: MoneyValue(amount: Decimal(offset), currency: .cny)))
        }
        repository.reverseHistory = true
        let store = RelayStore(repository: repository, credentialStore: InMemoryCredentialStore(),
            adapters: ProviderAdapterRegistry(adapters: []), automaticallyRefresh: false)
        let all = store.dailyUsage(accountID: account.id, limit: nil)
        try check(all.map(\.day) == all.map(\.day).sorted(), "Store projection restores repository history order")
        try check(store.dailyUsage(accountID: account.id, limit: 0) == all &&
                  store.dailyUsage(accountID: account.id, limit: -1) == all,
                  "Nonpositive projected history limits remain unlimited")
        let gatewayRepository = InMemoryLocalRepository()
        let gateway = AccountConfiguration(displayName: "new gateway", providerKind: .workbuddy2api,
                                           siteOrigin: URL(string: "http://localhost:7998")!)
        try gatewayRepository.upsertAccount(gateway)
        let gatewayStore = RelayStore(repository: gatewayRepository, credentialStore: InMemoryCredentialStore(),
            adapters: ProviderAdapterRegistry(adapters: []), automaticallyRefresh: false)
        try check(gatewayStore.gatewayNotices.contains(where: { $0.contains("尚未同步内部账号") }),
                  "A new unsynced gateway produces its existing diagnostic notice")
    }
}
