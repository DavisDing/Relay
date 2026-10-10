import Foundation

/// Injected time/sleep makes queue, cancellation and cooldown tests deterministic.
@MainActor
public struct RefreshClock {
    public var now: () -> Date
    public var sleep: (TimeInterval) async throws -> Void
    public init(now: @escaping () -> Date = Date.init,
                sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 86_400)) * 1_000_000_000))
                }) {
        self.now = now
        self.sleep = sleep
    }
}

/// Owns tasks, coalesces account requests and limits global/per-origin traffic.
/// Cancelled running jobs retain their slot until they actually finish.
@MainActor
public final class RefreshScheduler {
    public typealias Operation = (AccountConfiguration, Bool) async -> AccountRefreshResult
    public enum AttemptResult {
        case completed(AccountRefreshResult)
        case retry(at: Date)
    }
    public typealias AttemptOperation = (AccountConfiguration, Bool, Int) async -> AttemptResult
    /// Cancellation handlers run off-actor: record interest loss synchronously.
    private final class CancellationTicket: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    private struct Subscriber {
        let ticket: CancellationTicket
        let continuation: CheckedContinuation<AccountRefreshResult, Never>
    }
    private final class Job {
        let id = UUID()
        let account: AccountConfiguration
        let origin: String
        var forceRateRefresh: Bool
        var priority: Int
        var waiters: [UUID: Subscriber] = [:]
        var task: Task<Void, Never>?
        var cancelled = false
        var attempt = 0
        var notBefore: Date?
        init(account: AccountConfiguration, force: Bool, source: RefreshSource) {
            self.account = account
            self.origin = RefreshScheduler.originKey(account.siteOrigin)
            self.forceRateRefresh = force
            self.priority = source.priority
        }
    }

    private let concurrency: Int
    private let clock: RefreshClock
    private let operation: AttemptOperation
    private var jobs: [UUID: Job] = [:]
    private var accountJobs: [UUID: UUID] = [:]
    private var queue: [UUID] = []
    private var cooldowns: [String: Date] = [:]
    private var wakeTask: Task<Void, Never>?
    public var onPhaseChange: ((UUID, AccountRefreshPhase) -> Void)?
    public var onCancellation: ((UUID) -> Void)?

    public convenience init(maxConcurrentAccounts: Int = 3, clock: RefreshClock? = nil, operation: @escaping Operation) {
        self.init(maxConcurrentAccounts: maxConcurrentAccounts, clock: clock, attemptOperation: { account, force, _ in
            .completed(await operation(account, force))
        })
    }

    public init(maxConcurrentAccounts: Int = 3, clock: RefreshClock? = nil, attemptOperation: @escaping AttemptOperation) {
        concurrency = max(1, maxConcurrentAccounts)
        self.clock = clock ?? RefreshClock()
        self.operation = attemptOperation
    }

    public func refresh(account: AccountConfiguration, forceRateRefresh: Bool, source: RefreshSource) async -> AccountRefreshResult {
        let waiterID = UUID()
        let ticket = CancellationTicket()
        if Task.isCancelled { return .cancelled(account.id) }
        let result: AccountRefreshResult = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || ticket.isCancelled { continuation.resume(returning: .cancelled(account.id)); return }
                let job: Job
                if let id = accountJobs[account.id], let existing = jobs[id], !existing.cancelled {
                    job = existing
                    if job.task == nil { job.forceRateRefresh = job.forceRateRefresh || forceRateRefresh }
                    job.priority = max(job.priority, source.priority)
                } else {
                    job = Job(account: account, force: forceRateRefresh, source: source)
                    jobs[job.id] = job
                    accountJobs[account.id] = job.id
                    queue.append(job.id)
                    onPhaseChange?(account.id, .queued)
                }
                job.waiters[waiterID] = Subscriber(ticket: ticket, continuation: continuation)
                pump()
            }
        }, onCancel: {
            ticket.cancel()
            Task { @MainActor [weak self] in self?.cancelWaiter(accountID: account.id, waiterID: waiterID) }
        })
        return Task.isCancelled || ticket.isCancelled ? .cancelled(account.id) : result
    }

    /// Checked immediately before atomic commit, without an intervening actor hop.
    public func hasInterestedSubscribers(accountID: UUID) -> Bool {
        guard let id = accountJobs[accountID], let job = jobs[id], !job.cancelled else { return false }
        return job.waiters.values.contains { !$0.ticket.isCancelled }
    }

    public func cancel(accountID: UUID) {
        for job in Array(jobs.values) where job.account.id == accountID {
            cancel(job)
        }
        pump()
    }

    public func cancelAll() {
        wakeTask?.cancel()
        wakeTask = nil
        for job in Array(jobs.values) { cancel(job) }
    }

    public func recordRateLimit(for origin: URL, retryAfter: TimeInterval?) -> Date {
        let delay = min(Self.safeRetryDelay(retryAfter), max(0, Date.distantFuture.timeIntervalSince(clock.now())))
        let key = Self.originKey(origin)
        let until = max(cooldowns[key] ?? .distantPast, clock.now().addingTimeInterval(delay))
        cooldowns[key] = until
        return until
    }

    public static func safeRetryDelay(_ value: TimeInterval?) -> TimeInterval {
        guard let value, value.isFinite, value > 0 else { return 60 }
        return value
    }

    nonisolated private static func originKey(_ url: URL) -> String {
        // Deliberately stricter than provider grouping: all adapters to one origin share a slot.
        let scheme = url.scheme?.lowercased() ?? "https"
        return "\(scheme)://\(url.host?.lowercased() ?? ""):\(url.port ?? (scheme == "http" ? 80 : 443))"
    }

    private func cancelWaiter(accountID: UUID, waiterID: UUID) {
        guard let job = jobs.values.first(where: { $0.account.id == accountID && $0.waiters[waiterID] != nil }),
              let waiter = job.waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(returning: .cancelled(accountID))
        if job.waiters.isEmpty { cancel(job); pump() }
    }

    private func cancel(_ job: Job) {
        job.cancelled = true
        if accountJobs[job.account.id] == job.id {
            onCancellation?(job.account.id)
            accountJobs.removeValue(forKey: job.account.id)
        }
        job.task?.cancel()
        // A running adapter can be noncooperative. Don't free its origin prematurely.
        if job.task == nil { finish(job, result: .cancelled(job.account.id)) }
    }

    private func pump() {
        wakeTask?.cancel()
        wakeTask = nil
        queue = queue.filter { jobs[$0] != nil }
        queue.sort { (jobs[$0]?.priority ?? 0) > (jobs[$1]?.priority ?? 0) }
        var running = jobs.values.filter { $0.task != nil }
        let now = clock.now()
        cooldowns = cooldowns.filter { $0.value > now }
        for id in queue {
            guard running.count < concurrency else { break }
            guard let job = jobs[id], !job.cancelled,
                  !running.contains(where: { $0.origin == job.origin || $0.account.id == job.account.id }) else { continue }
            let until = max(cooldowns[job.origin] ?? .distantPast, job.notBefore ?? .distantPast)
            if until > now {
                onPhaseChange?(job.account.id, .backingOff(until: until))
                continue
            }
            queue.removeAll { $0 == id }
            onPhaseChange?(job.account.id, .refreshing)
            job.task = Task { @MainActor [weak self, weak job] in
                guard let self, let job else { return }
                let result = await self.operation(job.account, job.forceRateRefresh, job.attempt)
                // The actual request has returned. Waiting retries can now release
                // the global slot; cancelled noncooperative requests reach here too.
                job.task = nil
                if job.cancelled {
                    self.finish(job, result: .cancelled(job.account.id))
                } else {
                    switch result {
                    case .completed(let result): self.finish(job, result: result)
                    case .retry(let until):
                        job.attempt += 1
                        job.notBefore = until
                        self.queue.append(job.id)
                        self.onPhaseChange?(job.account.id, .backingOff(until: until))
                    }
                }
                self.pump()
            }
            running.append(job)
        }
        let blockedUntil = queue.compactMap { id -> Date? in
            guard let job = jobs[id] else { return nil }
            let until = max(cooldowns[job.origin] ?? .distantPast, job.notBefore ?? .distantPast)
            return until > now ? until : nil
        }.min()
        if let until = blockedUntil {
            wakeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.clock.sleep(max(0, until.timeIntervalSince(self.clock.now()))) }
                catch { return }
                if !Task.isCancelled { self.pump() }
            }
        }
    }

    private func finish(_ job: Job, result: AccountRefreshResult) {
        jobs.removeValue(forKey: job.id)
        queue.removeAll { $0 == job.id }
        if accountJobs[job.account.id] == job.id {
            accountJobs.removeValue(forKey: job.account.id)
            onPhaseChange?(job.account.id, .idle)
        } else if accountJobs[job.account.id] == nil {
            onPhaseChange?(job.account.id, .idle)
        }
        for subscriber in job.waiters.values {
            subscriber.continuation.resume(returning: subscriber.ticket.isCancelled ? .cancelled(job.account.id) : result)
        }
        job.waiters.removeAll()
    }
}
