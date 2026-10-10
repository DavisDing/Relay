import Foundation

public struct HistoryCoverage: Sendable, Equatable {
    public let days: Int
    public let knownDays: Int
    public let missingDays: [Date]
    public var isComplete: Bool { missingDays.isEmpty }

    public static func calculate(records: [DailyUsageRecord], accountID: UUID, days: Int,
                                 now: Date = Date(), calendar: Calendar = .current, currency: Currency? = nil) -> Self {
        let count = days == 30 ? 30 : 7
        let today = calendar.startOfDay(for: now)
        let known = Set(records.filter { record in
            guard record.accountID == accountID, let spend = record.spend,
                  !spend.amount.isNaN, spend.amount >= 0 else { return false }
            return currency == nil || spend.currency == currency
        }.map { calendar.startOfDay(for: $0.day) })
        let expected = (0..<count).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let missing = expected.filter { !known.contains($0) }
        return Self(days: count, knownDays: count - missing.count, missingDays: missing)
    }
}

public struct HistoryBackfillState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case queued, running, cancelling, completed, cancelled, failed, unavailable }
    public let requestedDays: Int
    public var processedDays: Int
    public var availableDays: Int
    public var phase: Phase
    public var message: String
    public var isActive: Bool { phase == .queued || phase == .running || phase == .cancelling }
    public var progress: Double { Double(processedDays) / Double(max(1, requestedDays - 1)) }
    public init(requestedDays: Int, processedDays: Int = 0, availableDays: Int = 0,
                phase: Phase = .queued, message: String = "等待历史查询") {
        self.requestedDays = requestedDays == 30 ? 30 : 7
        self.processedDays = processedDays
        self.availableDays = availableDays
        self.phase = phase
        self.message = message
    }
}

/// A shared network permit used by normal refreshes and explicit backfills.
/// An uncooperative cancelled request retains its permit until it returns.
@MainActor
final class HistoryBackfillRequestGate {
    private final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    private struct Waiter {
        let id: UUID
        let origin: String
        let ticket: Ticket
        let continuation: CheckedContinuation<Void, Error>
    }
    private let maximum: Int
    private let clock: RefreshClock
    private var active: Set<String> = []
    private var waiters: [Waiter] = []
    private var cooldowns: [String: Date] = [:]
    private var wakeTask: Task<Void, Never>?
    init(maximum: Int, clock: RefreshClock) { self.maximum = max(1, maximum); self.clock = clock }
    static func origin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "https"
        return "\(scheme)://\(url.host?.lowercased() ?? ""):\(url.port ?? (scheme == "http" ? 80 : 443))"
    }
    func acquire(_ url: URL) async throws {
        let origin = Self.origin(url), id = UUID(), ticket = Ticket()
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if ticket.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waiters.append(Waiter(id: id, origin: origin, ticket: ticket, continuation: continuation))
                pump()
            }
        }, onCancel: {
            ticket.cancel()
            Task { @MainActor [weak self] in self?.cancel(id) }
        })
        if ticket.isCancelled || Task.isCancelled { release(url); throw CancellationError() }
    }
    func release(_ url: URL) { active.remove(Self.origin(url)); pump() }
    func recordRateLimit(_ url: URL, until: Date) {
        let origin = Self.origin(url)
        cooldowns[origin] = max(cooldowns[origin] ?? .distantPast, until)
        pump()
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        pump()
    }
    private func pump() {
        wakeTask?.cancel(); wakeTask = nil
        let now = clock.now()
        cooldowns = cooldowns.filter { $0.value > now }
        var retained: [Waiter] = []
        for waiter in waiters {
            if waiter.ticket.isCancelled { waiter.continuation.resume(throwing: CancellationError()) }
            else if active.count < maximum && !active.contains(waiter.origin) && cooldowns[waiter.origin] == nil {
                active.insert(waiter.origin)
                waiter.continuation.resume()
            } else { retained.append(waiter) }
        }
        waiters = retained
        if let until = retained.compactMap({ cooldowns[$0.origin] }).min() {
            wakeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.clock.sleep(max(0, until.timeIntervalSince(self.clock.now()))) }
                catch { return }
                if !Task.isCancelled { self.pump() }
            }
        }
    }
}
