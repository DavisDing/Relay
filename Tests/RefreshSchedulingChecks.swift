import Foundation

private struct SchedulingFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private func schedulingCheck(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw SchedulingFailure(description: message) }
}

@MainActor
private func eventually(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<10_000 {
        if condition() { return }
        await Task.yield()
    }
    throw SchedulingFailure(description: "Timed out: " + message)
}

@MainActor
private final class SchedulingProbe {
    var started: [UUID] = []
    var peak = 0
    var active: Set<UUID> = []
    var pending: [UUID: CheckedContinuation<Void, Never>] = [:]
    func run(_ account: AccountConfiguration, force: Bool) async -> AccountRefreshResult {
        started.append(account.id)
        active.insert(account.id)
        peak = max(peak, active.count)
        // Deliberately noncooperative to test that cancel does not free a running slot early.
        await withCheckedContinuation { pending[account.id] = $0 }
        active.remove(account.id)
        return AccountRefreshResult(accountID: account.id, snapshot: schedulingSnapshot(account.id), error: nil)
    }
    func finish(_ id: UUID) { pending.removeValue(forKey: id)?.resume() }
}

private func schedulingSnapshot(_ id: UUID) -> ProviderSnapshot {
    ProviderSnapshot(accountID: id, balance: MoneyValue(amount: 100, currency: .cny),
                     todaySpend: nil, monthSpend: nil, requestCount: nil, capabilities: [.balance],
                     freshness: .fresh, rate: AccountRate(accountID: id, source: .providerNativeCurrency, nativeCurrency: .cny))
}

private func schedulingAccount(_ host: String) -> AccountConfiguration {
    AccountConfiguration(displayName: "fixture", providerKind: .pipio, siteOrigin: URL(string: "https://\(host).example")!)
}

@MainActor
private final class ManualRefreshTime {
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    var sleepers: [(Date, CheckedContinuation<Void, Error>)] = []
    var clock: RefreshClock {
        RefreshClock(now: { self.now }, sleep: { duration in
            try Task.checkCancellation()
            if duration <= 0 { return }
            try await withCheckedThrowingContinuation { self.sleepers.append((self.now.addingTimeInterval(duration), $0)) }
            try Task.checkCancellation()
        })
    }
    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        let ready = sleepers.filter { $0.0 <= now }
        sleepers.removeAll { $0.0 <= now }
        ready.forEach { $0.1.resume() }
    }
}

@MainActor
private final class ControlledSchedulingAdapter: ProviderAdapter {
    nonisolated let kind: ProviderKind = .pipio
    var starts = 0
    var failWith: ProviderError?
    var errorsByID: [UUID: ProviderError] = [:]
    var startsByID: [UUID: Int] = [:]
    var blocked = false
    var beforeReturn: (() -> Void)?
    var continuation: CheckedContinuation<Void, Never>?
    func fetchAccountRate(for account: AccountConfiguration, credential: ProviderCredential) async throws -> AccountRate {
        AccountRate(accountID: account.id, source: .providerNativeCurrency, nativeCurrency: .cny)
    }
    func validateAccount(_ account: AccountConfiguration, credential: ProviderCredential) async throws {}
    func fetchSnapshot(for account: AccountConfiguration, credential: ProviderCredential, rate: AccountRate, now: Date, calendar: Calendar) async throws -> ProviderSnapshot {
        starts += 1
        startsByID[account.id, default: 0] += 1
        if let error = errorsByID[account.id] { throw error }
        if let failWith { throw failWith }
        if blocked { await withCheckedContinuation { continuation = $0 } }
        beforeReturn?()
        return schedulingSnapshot(account.id)
    }
    func release() { continuation?.resume(); continuation = nil }
}

private struct FailedCredentialRead: CredentialStore {
    let error: CredentialStoreError
    func read(reference: String) async throws -> ProviderCredential { throw error }
    func save(_ credential: ProviderCredential, reference: String) async throws {}
    func delete(reference: String) async throws {}
}

@MainActor
public enum RefreshSchedulingChecks {
    public static func run() async throws {
        try await boundedAndMerged()
        try await subscriberCancellation()
        try await cancellationGuardsCommit()
        try await cancellationRaceAtCommit()
        try await normalizedHTTPOrigin()
        try await sharedCooldown()
        try await credentialStorageClassification()
        try await longBackoffIsolationAndScheduledProgress()
        try await retryFailureAndCancellation()
        try healthAndHeaders()
        print("PASSED: bounded origin concurrency, request coalescing, subscriber cancellation, deleted/edited-account guards, cooldown and health categories")
    }

    private static func boundedAndMerged() async throws {
        let probe = SchedulingProbe()
        let scheduler = RefreshScheduler(maxConcurrentAccounts: 2, operation: probe.run)
        let a = schedulingAccount("a"), sameOrigin = schedulingAccount("a"), b = schedulingAccount("b"), c = schedulingAccount("c")
        let first = Task { await scheduler.refresh(account: a, forceRateRefresh: false, source: .scheduled) }
        try await eventually("first starts") { probe.started.count == 1 }
        let duplicate = Task { await scheduler.refresh(account: a, forceRateRefresh: true, source: .manualAccount) }
        let same = Task { await scheduler.refresh(account: sameOrigin, forceRateRefresh: false, source: .scheduled) }
        let other = Task { await scheduler.refresh(account: b, forceRateRefresh: false, source: .scheduled) }
        try await eventually("other origin proceeds") { probe.started.contains(b.id) }
        let last = Task { await scheduler.refresh(account: c, forceRateRefresh: false, source: .scheduled) }
        for _ in 0..<50 { await Task.yield() }
        try schedulingCheck(probe.started.count == 2 && probe.peak == 2, "Global slots bounded; same origin and duplicate must wait/coalesce")
        probe.finish(a.id)
        try await eventually("queued job proceeds") { probe.started.count == 3 }
        let firstResult = await first.value, duplicateResult = await duplicate.value
        try schedulingCheck(firstResult.isSuccess && duplicateResult.isSuccess, "Coalesced subscribers share success")
        probe.finish(b.id)
        try await eventually("all independent accounts start") { probe.started.count == 4 }
        probe.finish(sameOrigin.id); probe.finish(c.id)
        _ = await (same.value, other.value, last.value)
        try schedulingCheck(probe.started.filter { $0 == a.id }.count == 1 && probe.peak <= 2, "Never duplicate an in-flight account")
    }

    private static func subscriberCancellation() async throws {
        let probe = SchedulingProbe()
        let scheduler = RefreshScheduler(operation: probe.run)
        let account = schedulingAccount("shared")
        let a = Task { await scheduler.refresh(account: account, forceRateRefresh: false, source: .scheduled) }
        try await eventually("shared start") { probe.started.count == 1 }
        let b = Task { await scheduler.refresh(account: account, forceRateRefresh: false, source: .manualAccount) }
        for _ in 0..<50 { await Task.yield() }
        a.cancel()
        let cancelled = await a.value
        try schedulingCheck(cancelled.isCancelled, "Cancelled subscriber gets cancellation, not failure")
        probe.finish(account.id)
        let result = await b.value
        try schedulingCheck(result.isSuccess && probe.started.count == 1, "Cancelling one subscriber preserves another's request")
    }

    private static func cancellationGuardsCommit() async throws {
        let repo = InMemoryLocalRepository(), credentials = InMemoryCredentialStore()
        let adapter = ControlledSchedulingAdapter(); adapter.blocked = true
        var account = schedulingAccount("cancel")
        try repo.upsertAccount(account)
        try await credentials.save(ProviderCredential(secret: "fixture-only"), reference: account.credentialReference)
        let coordinator = RefreshCoordinator(repository: repo, credentialStore: credentials, adapters: ProviderAdapterRegistry(adapters: [adapter]), maxRetryCount: 0)
        let pending = Task { await coordinator.refresh(accountID: account.id) }
        try await eventually("adapter blocked") { adapter.starts == 1 }
        coordinator.cancel(accountID: account.id)
        try repo.deleteAccount(id: account.id)
        adapter.release()
        let cancelled = await pending.value
        try schedulingCheck(cancelled.isCancelled && cancelled.error == nil, "Cancellation is not a provider error")
        try schedulingCheck(try repo.snapshot(accountID: account.id) == nil, "Cancelled refresh cannot resurrect deleted account snapshot")
        try schedulingCheck(coordinator.health[account.id]?.consecutiveFailures == 0, "Cancellation doesn't increment health failures")

        account = schedulingAccount("edited")
        try repo.upsertAccount(account)
        try await credentials.save(ProviderCredential(secret: "fixture-only"), reference: account.credentialReference)
        let edited = Task { await coordinator.refresh(accountID: account.id) }
        try await eventually("edited request blocked") { adapter.starts == 2 }
        account.updatedAt = account.updatedAt.addingTimeInterval(1)
        try repo.upsertAccount(account)
        adapter.release()
        let superseded = await edited.value
        try schedulingCheck(superseded.isCancelled && (try repo.snapshot(accountID: account.id)) == nil, "Changed account rejects old result even without explicit cancellation")

        adapter.blocked = false
        let recovered = await coordinator.refresh(accountID: account.id)
        try schedulingCheck(recovered.isSuccess && coordinator.health[account.id]?.consecutiveFailures == 0, "Next refresh recovers normally")
    }

    private static func cancellationRaceAtCommit() async throws {
        let repo = InMemoryLocalRepository(), credentials = InMemoryCredentialStore()
        let adapter = ControlledSchedulingAdapter()
        let account = schedulingAccount("race")
        try repo.upsertAccount(account)
        try await credentials.save(ProviderCredential(secret: "fixture-only"), reference: account.credentialReference)
        let coordinator = RefreshCoordinator(repository: repo, credentialStore: credentials, adapters: ProviderAdapterRegistry(adapters: [adapter]), maxRetryCount: 0)
        let task = Task { await coordinator.refresh(accountID: account.id) }
        // Cancel subscriber synchronously inside the provider return, before the deferred actor cleanup.
        adapter.beforeReturn = { task.cancel() }
        let result = await task.value
        try schedulingCheck(result.isCancelled && (try repo.snapshot(accountID: account.id)) == nil, "Last-subscriber cancellation recorded before actor hop blocks commit")
        try schedulingCheck(coordinator.health[account.id]?.consecutiveFailures == 0, "Cancellation race cannot count as health failure")
        adapter.beforeReturn = nil
        adapter.blocked = true
        let equalTimestampEdit = Task { await coordinator.refresh(accountID: account.id) }
        try await eventually("same timestamp edit blocked") { adapter.continuation != nil }
        var changed = account
        changed.manualUSDToCNY = 7
        try repo.upsertAccount(changed)
        adapter.release()
        let oldResult = await equalTimestampEdit.value
        try schedulingCheck(oldResult.isCancelled && (try repo.snapshot(accountID: account.id)) == nil, "Equal timestamp doesn't permit obsolete configuration commit")
    }

    private static func normalizedHTTPOrigin() async throws {
        let probe = SchedulingProbe()
        let scheduler = RefreshScheduler(maxConcurrentAccounts: 3, operation: probe.run)
        let a = AccountConfiguration(displayName: "local", providerKind: .workbuddy2api, siteOrigin: URL(string: "http://localhost")!)
        let b = AccountConfiguration(displayName: "local", providerKind: .workbuddy2api, siteOrigin: URL(string: "http://localhost:80")!)
        let first = Task { await scheduler.refresh(account: a, forceRateRefresh: false, source: .scheduled) }
        try await eventually("loopback first starts") { probe.started.count == 1 }
        let second = Task { await scheduler.refresh(account: b, forceRateRefresh: false, source: .scheduled) }
        for _ in 0..<100 { await Task.yield() }
        try schedulingCheck(probe.started.count == 1, "Implicit and explicit HTTP port 80 must share an origin")
        probe.finish(a.id)
        try await eventually("loopback serialized") { probe.started.count == 2 }
        probe.finish(b.id)
        _ = await (first.value, second.value)
    }

    private static func sharedCooldown() async throws {
        let repo = InMemoryLocalRepository(), credentials = InMemoryCredentialStore()
        let adapter = ControlledSchedulingAdapter(); adapter.failWith = .rateLimited(retryAfter: 120)
        let a = schedulingAccount("limited"), b = schedulingAccount("limited")
        for account in [a, b] {
            try repo.upsertAccount(account)
            try await credentials.save(ProviderCredential(secret: "fixture-only"), reference: account.credentialReference)
        }
        let time = ManualRefreshTime()
        let coordinator = RefreshCoordinator(repository: repo, credentialStore: credentials, adapters: ProviderAdapterRegistry(adapters: [adapter]), maxRetryCount: 0, clock: time.clock)
        let failed = await coordinator.refresh(accountID: a.id)
        try schedulingCheck(failed.error == .rateLimited(retryAfter: 120), "Rate limit remains classified")
        try schedulingCheck(coordinator.health[a.id]?.issue == .rateLimit && coordinator.health[a.id]?.consecutiveFailures == 1, "Final failure counted once")
        adapter.failWith = nil
        let queued = Task { await coordinator.refresh(accountID: b.id) }
        try await eventually("cooldown waiter sleeps") { !time.sleepers.isEmpty }
        try schedulingCheck(adapter.starts == 1, "Another account cannot bypass origin cooldown")
        time.advance(119)
        for _ in 0..<30 { await Task.yield() }
        try schedulingCheck(adapter.starts == 1, "Retry-After must not be shortened to 60 seconds")
        time.advance(1)
        let recovered = await queued.value
        try schedulingCheck(recovered.isSuccess && adapter.starts == 2, "Cooldown expiry resumes queue")
    }

    private static func longBackoffIsolationAndScheduledProgress() async throws {
        let repo = InMemoryLocalRepository(), credentials = InMemoryCredentialStore()
        let adapter = ControlledSchedulingAdapter(), time = ManualRefreshTime()
        let limited = (0..<3).map { schedulingAccount("limited-\($0)") }
        let healthy = schedulingAccount("healthy")
        for account in limited + [healthy] {
            try repo.upsertAccount(account)
            try await credentials.save(ProviderCredential(secret: "fixture-only"), reference: account.credentialReference)
        }
        for account in limited { adapter.errorsByID[account.id] = .rateLimited(retryAfter: 3_600) }
        let coordinator = RefreshCoordinator(repository: repo, credentialStore: credentials,
            adapters: ProviderAdapterRegistry(adapters: [adapter]), clock: time.clock)
        var results: [UUID: Int] = [:]
        coordinator.onResult = { result in results[result.accountID, default: 0] += 1 }
        // Fill all three execution slots before introducing the healthy origin.
        let tasks = limited.map { account in Task { await coordinator.refresh(accountID: account.id) } }
        try await eventually("three retries queued") {
            limited.allSatisfy { coordinator.health[$0.id]?.retryAt == time.now.addingTimeInterval(3_600) }
        }
        coordinator.enqueueScheduledRefreshes(interval: 60)
        try await eventually("fourth origin completes while all others cool down") { results[healthy.id] == 1 }
        for _ in 0..<30 { coordinator.enqueueScheduledRefreshes(interval: 60); await Task.yield() }
        try schedulingCheck(adapter.startsByID[healthy.id] == 1, "Repeated triggers must not duplicate an account within its period")
        for cycle in 2...3 {
            time.advance(60)
            coordinator.enqueueScheduledRefreshes(interval: 60)
            try await eventually("healthy account completes next scheduled period") {
                coordinator.enqueueScheduledRefreshes(interval: 60)
                return results[healthy.id] == cycle
            }
        }
        try schedulingCheck(limited.allSatisfy { adapter.startsByID[$0.id] == 1 }, "Scheduled and manual subscribers cannot bypass origin cooldown")
        for account in limited { adapter.errorsByID.removeValue(forKey: account.id) }
        time.advance(3_480)
        for task in tasks {
            let result = await task.value
            try schedulingCheck(result.isSuccess, "Limited account resumes after its full hour")
        }
        try schedulingCheck(limited.allSatisfy { adapter.startsByID[$0.id] == 2 }, "Coalesced waiters perform exactly one retry per account")
        coordinator.cancelAll()
        time.advance(86_400)
    }

    private static func retryFailureAndCancellation() async throws {
        let repo = InMemoryLocalRepository(), credentials = InMemoryCredentialStore()
        let adapter = ControlledSchedulingAdapter(), time = ManualRefreshTime()
        let account = schedulingAccount("retry")
        try repo.upsertAccount(account)
        try await credentials.save(ProviderCredential(secret: "fixture-only"), reference: account.credentialReference)
        adapter.failWith = .transport
        let coordinator = RefreshCoordinator(repository: repo, credentialStore: credentials,
            adapters: ProviderAdapterRegistry(adapters: [adapter]), maxRetryCount: 1, clock: time.clock)
        let task = Task { await coordinator.refresh(accountID: account.id) }
        try await eventually("network backoff") { coordinator.health[account.id]?.retryAt != nil && !time.sleepers.isEmpty }
        try schedulingCheck(coordinator.health[account.id]?.issue == .network, "Network backoff must not be mislabeled as rate limit")
        time.advance(2)
        let result = await task.value
        try schedulingCheck(result.error == .transport && adapter.starts == 2, "Retry budget is retained across queued attempts")
        try schedulingCheck(coordinator.health[account.id]?.consecutiveFailures == 1, "One refresh failure is counted once across attempts")
        let cancelled = Task { await coordinator.refresh(accountID: account.id) }
        try await eventually("second network backoff") { adapter.starts == 3 && coordinator.health[account.id]?.retryAt != nil }
        coordinator.cancel(accountID: account.id)
        let cancelledResult = await cancelled.value
        try schedulingCheck(cancelledResult.isCancelled && coordinator.health[account.id]?.consecutiveFailures == 1,
                            "Cancelling delayed work preserves previous failure count")
        time.advance(3_600)
        for _ in 0..<30 { await Task.yield() }
        try schedulingCheck(adapter.starts == 3, "Cancelled delayed work cannot resume")
    }

    private static func credentialStorageClassification() async throws {
        for (error, expected) in [(CredentialStoreError.notFound, AccountHealthIssue.credentials), (.decodingFailed, .storage)] {
            let repo = InMemoryLocalRepository(), adapter = ControlledSchedulingAdapter()
            let account = schedulingAccount("credentials")
            try repo.upsertAccount(account)
            let coordinator = RefreshCoordinator(repository: repo, credentialStore: FailedCredentialRead(error: error), adapters: ProviderAdapterRegistry(adapters: [adapter]))
            _ = await coordinator.refresh(accountID: account.id)
            try schedulingCheck(coordinator.health[account.id]?.issue == expected, "Missing key and unreadable credential file must differ")
            try schedulingCheck(adapter.starts == 0 && coordinator.health[account.id]?.consecutiveFailures == 1, "Credential/storage errors must not issue provider requests or retry")
        }
    }

    private static func healthAndHeaders() throws {
        try schedulingCheck(AccountHealthIssue(error: .unauthorized) == .credentials, "Authentication classification")
        try schedulingCheck(AccountHealthIssue(error: .forbidden) == .permission, "Permission classification")
        try schedulingCheck(AccountHealthIssue(error: .transport) == .network, "Network classification")
        try schedulingCheck(AccountHealthIssue(error: .incompatibleResponse) == .incompatibleResponse, "Contract classification")
        try schedulingCheck(AccountHealthIssue(error: .storageUnavailable) == .storage, "Storage isn't a network failure")
        try schedulingCheck(RefreshScheduler.safeRetryDelay(172_800) == 172_800, "Long cooldown cannot be shortened to one day")
        try schedulingCheck(HTTPResponseValidator.retryAfterInterval("120") == 120, "Numeric Retry-After")
        let date = Date(timeIntervalSince1970: 0)
        try schedulingCheck(HTTPResponseValidator.retryAfterInterval("Thu, 01 Jan 1970 00:02:00 GMT", now: date) == 120, "HTTP-date Retry-After")
        try schedulingCheck(HTTPResponseValidator.retryAfterInterval("NaN") == nil, "Nonfinite header rejected")
    }
}
