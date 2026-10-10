import Foundation

private struct HistoryCheckFailure: Error, CustomStringConvertible { let description: String }
@MainActor
private func historyCheck(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw HistoryCheckFailure(description: message) }
}
@MainActor
private func waitForHistory(_ coordinator: RefreshCoordinator, id: UUID) async throws {
    for _ in 0..<30_000 {
        if let state = coordinator.historyBackfillStates[id], !state.isActive { return }
        await Task.yield()
    }
    throw HistoryCheckFailure(description: "Timed out waiting for history")
}

@MainActor
private final class HistoryFixtureAdapter: ProviderAdapter {
    nonisolated let kind: ProviderKind
    var calls = 0
    var blocked = false
    var continuation: CheckedContinuation<Void, Never>?
    var beforeReturn: (() -> Void)?
    var omitEverySecondDay = false
    var includeToday = false
    var requestedRanges: [(Date, Int)] = []
    init(kind: ProviderKind = .pipio) { self.kind = kind }
    func validateAccount(_ account: AccountConfiguration, credential: ProviderCredential) async throws {}
    func fetchAccountRate(for account: AccountConfiguration, credential: ProviderCredential) async throws -> AccountRate {
        AccountRate(accountID: account.id, source: .providerNativeCurrency, nativeCurrency: .cny)
    }
    func fetchSnapshot(for account: AccountConfiguration, credential: ProviderCredential,
                       rate: AccountRate, now: Date, calendar: Calendar) async throws -> ProviderSnapshot {
        ProviderSnapshot(accountID: account.id, balance: MoneyValue(amount: 100, currency: .cny),
            todaySpend: MoneyValue(amount: 5, currency: .cny), monthSpend: nil, requestCount: nil,
            capabilities: [.balance, .todayUsage], freshness: .fresh, fetchedAt: now, rate: rate)
    }
    func fetchDailyUsage(for account: AccountConfiguration, credential: ProviderCredential, rate: AccountRate,
                         endingAt: Date, days: Int, calendar: Calendar) async throws -> [DailyUsageRecord] {
        calls += 1; requestedRanges.append((endingAt, days))
        if blocked { await withCheckedContinuation { continuation = $0 } }
        beforeReturn?()
        if omitEverySecondDay && calls.isMultiple(of: 2) { return [] }
        let day = kind == .pipio ? calendar.date(byAdding: .day, value: -1, to: endingAt)! : endingAt
        var records = [DailyUsageRecord(accountID: account.id, day: day, spend: MoneyValue(amount: 2, currency: .cny))]
        if includeToday { records.append(DailyUsageRecord(accountID: account.id, day: endingAt, spend: MoneyValue(amount: 999, currency: .cny))) }
        return records
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
public enum HistoryBackfillChecks {
    public static func run() async throws {
        let calendar = DeepSeekUsageService.historyCalendar
        let now = Date(timeIntervalSince1970: 1_791_630_000)
        let today = calendar.startOfDay(for: now)
        let account = AccountConfiguration(displayName: "History fixture", providerKind: .pipio,
                                           siteOrigin: URL(string: "https://history.example.invalid")!)
        let known = DailyUsageRecord(accountID: account.id, day: today, spend: MoneyValue(amount: 5, currency: .cny))
        let missing = DailyUsageRecord(accountID: account.id, day: calendar.date(byAdding: .day, value: -1, to: today)!, spend: nil)
        let incompatible = DailyUsageRecord(accountID: account.id, day: calendar.date(byAdding: .day, value: -2, to: today)!,
                                            spend: MoneyValue(amount: 0, currency: .usd))
        let foreign = DailyUsageRecord(accountID: UUID(), day: missing.day, spend: MoneyValue(amount: 0, currency: .cny))
        let coverage = HistoryCoverage.calculate(records: [known, missing, incompatible, foreign, known],
            accountID: account.id, days: 7, now: now, calendar: calendar, currency: .cny)
        try historyCheck(coverage.knownDays == 1 && coverage.missingDays.count == 6,
                         "Unknown, mixed currency, foreign and duplicate records never inflate coverage")
        let zero = DailyUsageRecord(accountID: account.id, day: missing.day, spend: MoneyValue(amount: 0, currency: .cny))
        try historyCheck(HistoryCoverage.calculate(records: [known, zero], accountID: account.id,
            days: 7, now: now, calendar: calendar).knownDays == 2, "Confirmed zero is an observed day")

        let repository = InMemoryLocalRepository()
        try repository.upsertAccount(account); try repository.upsertDailyUsage(known)
        let credentials = InMemoryCredentialStore()
        try await credentials.save(ProviderCredential(secret: "fixture-only", pipioUserID: "1"), reference: account.credentialReference)
        let adapter = HistoryFixtureAdapter(); adapter.omitEverySecondDay = true; adapter.includeToday = true
        let coordinator = RefreshCoordinator(repository: repository, credentialStore: credentials,
            adapters: ProviderAdapterRegistry(adapters: [adapter]), calendar: calendar,
            clock: RefreshClock(now: { now }))
        coordinator.startHistoryBackfill(accountID: account.id, days: 7)
        coordinator.startHistoryBackfill(accountID: account.id, days: 30)
        try await waitForHistory(coordinator, id: account.id)
        let records = try repository.dailyUsage(accountID: account.id, limit: nil)
        try historyCheck(adapter.calls == 6, "Repeated requests coalesce instead of spawning another task")
        try historyCheck(records.count == 4 && records.first(where: { $0.day == today })?.spend == known.spend,
                         "Backfill merges only valid historical days and preserves today's amount")
        try historyCheck(coordinator.historyBackfillStates[account.id]?.availableDays == 3,
                         "Empty provider dates remain missing, completion reports observed days")
        try historyCheck(adapter.requestedRanges.allSatisfy { $0.1 == 2 }, "Pipio requests one completed day per call")

        adapter.omitEverySecondDay = false; adapter.blocked = true
        coordinator.startHistoryBackfill(accountID: account.id, days: 7)
        for _ in 0..<10_000 { if adapter.continuation != nil { break }; await Task.yield() }
        try historyCheck(adapter.continuation != nil, "Cancellation fixture reached uncooperative request")
        coordinator.cancelHistoryBackfill(accountID: account.id)
        adapter.release()
        for _ in 0..<100 { await Task.yield() }
        try historyCheck(try repository.dailyUsage(accountID: account.id, limit: nil) == records,
                         "Cancelling an uncooperative adapter cannot commit partially fetched results")

        adapter.beforeReturn = {
            var edited = account; edited.displayName = "edited while loading"
            try? repository.upsertAccount(edited)
        }
        adapter.blocked = false
        coordinator.startHistoryBackfill(accountID: account.id, days: 7)
        try await waitForHistory(coordinator, id: account.id)
        try historyCheck(coordinator.historyBackfillStates[account.id]?.phase == .cancelled,
                         "Changed account configuration invalidates an in-flight backfill")
        try historyCheck(try repository.dailyUsage(accountID: account.id, limit: nil) == records,
                         "Edited configuration retains previously saved history")

        let deep = AccountConfiguration(displayName: "No platform token", providerKind: .deepseek,
                                        siteOrigin: URL(string: "https://api.deepseek.com")!)
        try repository.upsertAccount(deep)
        try await credentials.save(ProviderCredential(secret: "fixture-only"), reference: deep.credentialReference)
        let deepAdapter = HistoryFixtureAdapter(kind: .deepseek)
        let deepCoordinator = RefreshCoordinator(repository: repository, credentialStore: credentials,
            adapters: ProviderAdapterRegistry(adapters: [deepAdapter]), calendar: calendar, clock: RefreshClock(now: { now }))
        deepCoordinator.startHistoryBackfill(accountID: deep.id, days: 30)
        try await waitForHistory(deepCoordinator, id: deep.id)
        try historyCheck(deepCoordinator.historyBackfillStates[deep.id]?.phase == .unavailable && deepAdapter.calls == 0,
                         "DeepSeek API key alone does not imply historical coverage or send a platform query")
        try await credentials.save(ProviderCredential(secret: "fixture-only", deepSeekUserToken: "fixture-platform-only"), reference: deep.credentialReference)
        deepAdapter.includeToday = true
        deepCoordinator.startHistoryBackfill(accountID: deep.id, days: 30)
        try await waitForHistory(deepCoordinator, id: deep.id)
        try historyCheck(deepAdapter.calls == 1 && deepAdapter.requestedRanges.first?.1 == 30,
                         "DeepSeek monthly payloads are queried once per requested range")
        try historyCheck(try repository.dailyUsage(accountID: deep.id, limit: nil).isEmpty,
                         "DeepSeek result cannot overwrite today's snapshot-derived record")

        try await networkGate()
        print("PASSED: history coverage, truthful missing days, coalescing, today protection, cancellation/configuration guards, DeepSeek opt-in and shared request permits")
    }

    private static func networkGate() async throws {
        let gate = HistoryBackfillRequestGate(maximum: 1, clock: RefreshClock())
        let a = URL(string: "https://gate.example.invalid/a")!, b = URL(string: "https://other.example.invalid")!
        try await gate.acquire(a)
        var entered = false
        let waiting = Task { @MainActor in try await gate.acquire(b); entered = true; gate.release(b) }
        for _ in 0..<50 { await Task.yield() }
        try historyCheck(!entered, "Shared permit bounds concurrent history and refresh requests")
        waiting.cancel(); gate.release(a)
        do { try await waiting.value; throw HistoryCheckFailure(description: "Cancelled waiter acquired permit") }
        catch is CancellationError {}
        try await gate.acquire(b); gate.release(b)
        try historyCheck(!entered, "Cancelled waiting requests neither run nor leak a permit")
    }
}
