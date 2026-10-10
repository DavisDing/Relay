import Foundation

public struct AccountRefreshResult: Sendable {
    public let accountID: UUID
    public let snapshot: ProviderSnapshot?
    public let error: ProviderError?
    public let isCancelled: Bool
    public var isSuccess: Bool { snapshot != nil && error == nil && !isCancelled }
    public init(accountID: UUID, snapshot: ProviderSnapshot?, error: ProviderError?, isCancelled: Bool = false) {
        self.accountID = accountID; self.snapshot = snapshot; self.error = error; self.isCancelled = isCancelled
    }
    public static func cancelled(_ id: UUID) -> Self {
        Self(accountID: id, snapshot: nil, error: nil, isCancelled: true)
    }
}

@MainActor
public final class RefreshCoordinator {
    private let repository: any LocalRepository
    private let credentialStore: any CredentialStore
    private let adapters: ProviderAdapterRegistry
    private let rateService: RateService
    private let calendar: Calendar
    private let maxRetryCount: Int
    private let clock: RefreshClock
    private let maxConcurrentAccounts: Int
    public private(set) var health: [UUID: AccountHealth] = [:]
    public var onHealthChange: ((UUID, AccountHealth) -> Void)?
    public var onResult: ((AccountRefreshResult) -> Void)?
    public var onRepositoryError: ((String) -> Void)?
    public private(set) var historyBackfillStates: [UUID: HistoryBackfillState] = [:]
    public var onHistoryBackfillChange: ((UUID, HistoryBackfillState) -> Void)?
    public var onHistoryBackfillCommit: ((UUID) -> Void)?
    private var historyBackfillTasks: [UUID: (UUID, Task<Void, Never>)] = [:]
    private lazy var historyRequestGate = HistoryBackfillRequestGate(maximum: maxConcurrentAccounts, clock: clock)
    private var healthBeforeRetry: [UUID: AccountHealth] = [:]
    private lazy var scheduler: RefreshScheduler = {
        let scheduler = RefreshScheduler(maxConcurrentAccounts: maxConcurrentAccounts, clock: clock, attemptOperation: { [weak self] account, force, attempt in
            guard let self else { return .completed(.cancelled(account.id)) }
            return await self.execute(account: account, forceRateRefresh: force, attempt: attempt)
        })
        scheduler.onCancellation = { [weak self] id in
            guard let self, let previous = self.healthBeforeRetry.removeValue(forKey: id) else { return }
            self.restoreFailureState(id, from: previous)
        }
        scheduler.onPhaseChange = { [weak self] id, phase in
            self?.updateHealth(id) {
                $0.phase = phase
                if case .backingOff(let until) = phase {
                    $0.retryAt = until
                    if self?.healthBeforeRetry[id] == nil { $0.issue = .rateLimit }
                }
            }
        }
        return scheduler
    }()

    public init(
        repository: any LocalRepository,
        credentialStore: any CredentialStore,
        adapters: ProviderAdapterRegistry,
        rateService: RateService = RateService(),
        calendar: Calendar = .current,
        maxRetryCount: Int = 2,
        maxConcurrentAccounts: Int = 3,
        clock: RefreshClock? = nil
    ) {
        self.repository = repository
        self.credentialStore = credentialStore
        self.adapters = adapters
        self.rateService = rateService
        self.calendar = calendar
        self.maxRetryCount = max(0, maxRetryCount)
        self.maxConcurrentAccounts = max(1, maxConcurrentAccounts)
        self.clock = clock ?? RefreshClock()
    }

    public func refreshAll(forceRateRefresh: Bool = false, source: RefreshSource = .manualAll) async -> [AccountRefreshResult] {
        let accounts: [AccountConfiguration]
        do { accounts = try repository.fetchAccounts().filter(\.isEnabled) }
        catch { onRepositoryError?("无法读取账户列表，保留上次成功数据。"); return [] }
        return await withTaskGroup(of: AccountRefreshResult.self) { group in
            for account in accounts {
                group.addTask { await self.scheduler.refresh(account: account, forceRateRefresh: forceRateRefresh, source: source) }
            }
            var results: [UUID: AccountRefreshResult] = [:]
            for await result in group { results[result.accountID] = result }
            return accounts.compactMap { results[$0.id] }
        }
    }

    public func refresh(accountID: UUID, forceRateRefresh: Bool = false, source: RefreshSource = .manualAccount) async -> AccountRefreshResult {
        do {
            guard let account = try repository.account(id: accountID), account.isEnabled else {
                return .cancelled(accountID)
            }
            return await scheduler.refresh(account: account, forceRateRefresh: forceRateRefresh, source: source)
        } catch { return AccountRefreshResult(accountID: accountID, snapshot: nil, error: sanitized(error)) }
    }

    private var scheduledTasks: [UUID: (UUID, Task<Void, Never>)] = [:]
    private var scheduledAt: [UUID: Date] = [:]

    /// One subscriber per scheduled account, independent of whole-round completion.
    public func enqueueScheduledRefreshes(interval: TimeInterval) {
        let accounts: [AccountConfiguration]
        do { accounts = try repository.fetchAccounts().filter(\.isEnabled) }
        catch { onRepositoryError?("无法读取账户列表，保留上次成功数据。"); return }
        for account in accounts {
            guard scheduledTasks[account.id] == nil,
                  clock.now().timeIntervalSince(scheduledAt[account.id] ?? .distantPast) >= interval else { continue }
            let token = UUID()
            scheduledAt[account.id] = clock.now()
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.scheduler.refresh(account: account, forceRateRefresh: false, source: .scheduled)
                if self.scheduledTasks[account.id]?.0 == token { self.scheduledTasks.removeValue(forKey: account.id) }
            }
            scheduledTasks[account.id] = (token, task)
        }
    }

    public func cancel(accountID: UUID) {
        cancelHistoryBackfill(accountID: accountID)
        scheduledTasks.removeValue(forKey: accountID)?.1.cancel()
        scheduledAt.removeValue(forKey: accountID)
        scheduler.cancel(accountID: accountID)
    }
    public func cancelAll() {
        cancelAllHistoryBackfills()
        for (_, task) in scheduledTasks.values { task.cancel() }
        scheduledTasks.removeAll()
        scheduledAt.removeAll()
        scheduler.cancelAll()
    }

    private func updateHealth(_ id: UUID, _ update: (inout AccountHealth) -> Void) {
        var state = health[id] ?? AccountHealth()
        update(&state)
        health[id] = state
        onHealthChange?(id, state)
    }

    private func restoreFailureState(_ id: UUID, from previous: AccountHealth) {
        updateHealth(id) {
            $0.issue = previous.issue; $0.retryAt = previous.retryAt
            $0.consecutiveFailures = previous.consecutiveFailures
        }
    }

    private func execute(account: AccountConfiguration, forceRateRefresh: Bool, attempt: Int) async -> RefreshScheduler.AttemptResult {
        if attempt == 0 { healthBeforeRetry[account.id] = health[account.id] ?? AccountHealth() }
        do {
            try Task.checkCancellation()
            let snapshot = try await performRefresh(account: account, forceRateRefresh: forceRateRefresh)
            healthBeforeRetry.removeValue(forKey: account.id)
            updateHealth(account.id) {
                $0.lastSuccessAt = snapshot.fetchedAt; $0.consecutiveFailures = 0
                $0.issue = nil; $0.retryAt = nil; $0.freshness = snapshot.freshness
            }
            let result = AccountRefreshResult(accountID: account.id, snapshot: snapshot, error: nil)
            onResult?(result)
            return .completed(result)
        } catch {
            let providerError = sanitized(error)
            // A received Retry-After is authoritative even after cancellation.
            let until: Date?
            if case .rateLimited(let retryAfter) = providerError {
                until = scheduler.recordRateLimit(for: account.siteOrigin, retryAfter: retryAfter)
                if let until { historyRequestGate.recordRateLimit(account.siteOrigin, until: until) }
            } else { until = nil }
            if Task.isCancelled || error is CancellationError || !scheduler.hasInterestedSubscribers(accountID: account.id) {
                if let previous = healthBeforeRetry.removeValue(forKey: account.id) {
                    restoreFailureState(account.id, from: previous)
                }
                return .completed(.cancelled(account.id))
            }
            guard attempt < maxRetryCount, isRetryable(providerError) else {
                healthBeforeRetry.removeValue(forKey: account.id)
                updateHealth(account.id) {
                    $0.issue = AccountHealthIssue(error: providerError)
                    $0.consecutiveFailures += 1; $0.retryAt = until
                }
                let result = AccountRefreshResult(accountID: account.id, snapshot: nil, error: providerError)
                onResult?(result)
                return .completed(result)
            }
            let retryAt = until ?? clock.now().addingTimeInterval(retryDelay(for: providerError, attempt: attempt))
            updateHealth(account.id) {
                $0.issue = AccountHealthIssue(error: providerError)
                $0.retryAt = retryAt
            }
            return .retry(at: retryAt)
        }
    }

    private func performRefresh(account: AccountConfiguration, forceRateRefresh: Bool) async throws -> ProviderSnapshot {
        try await historyRequestGate.acquire(account.siteOrigin)
        defer { historyRequestGate.release(account.siteOrigin) }
        let credential = try await credentialStore.read(reference: account.credentialReference)
        let adapter = try adapters.adapter(for: account.providerKind)
        let oldSnapshot = try repository.snapshot(accountID: account.id)
        let rateResolution = try await rateService.resolve(
            account: account,
            credential: credential,
            adapter: adapter,
            persistedRate: oldSnapshot?.rate,
            forceRefresh: forceRateRefresh
        )
        try Task.checkCancellation()
        let fetched = try await adapter.fetchSnapshot(
            for: account,
            credential: credential,
            rate: rateResolution.rate,
            now: clock.now(),
            calendar: calendar
        )
        try Task.checkCancellation()
        // If an older gateway has no /v1/stats endpoint, keep the previous
        // stats baseline so a later successful response is not counted twice.
        let fetchedWithStats: ProviderSnapshot
        if account.providerKind == .workbuddy2api,
           fetched.workBuddyStats == nil,
           let oldStats = oldSnapshot?.workBuddyStats {
            fetchedWithStats = ProviderSnapshot(
                accountID: fetched.accountID,
                balance: fetched.balance,
                todaySpend: fetched.todaySpend,
                monthSpend: fetched.monthSpend,
                requestCount: fetched.requestCount,
                modelUsages: fetched.modelUsages,
                capabilities: fetched.capabilities,
                freshness: fetched.freshness,
                fetchedAt: fetched.fetchedAt,
                rate: fetched.rate,
                creditMetrics: fetched.creditMetrics,
                subAccounts: fetched.subAccounts,
                workBuddyStats: oldStats
            )
        } else {
            fetchedWithStats = fetched
        }
        let snapshot = rateResolution.isStale ? ProviderSnapshot(
            accountID: fetchedWithStats.accountID,
            balance: fetchedWithStats.balance,
            todaySpend: fetchedWithStats.todaySpend,
            monthSpend: fetchedWithStats.monthSpend,
            requestCount: fetchedWithStats.requestCount,
            modelUsages: fetchedWithStats.modelUsages,
            capabilities: fetchedWithStats.capabilities,
            freshness: .stale,
            fetchedAt: fetchedWithStats.fetchedAt,
            rate: fetchedWithStats.rate,
            creditMetrics: fetchedWithStats.creditMetrics,
            subAccounts: fetchedWithStats.subAccounts,
            workBuddyStats: fetchedWithStats.workBuddyStats
        ) : fetchedWithStats
        var dailyRecord: DailyUsageRecord?
        if account.providerKind == .workbuddy2api, let currentStats = snapshot.workBuddyStats {
            let previousStats = oldSnapshot?.workBuddyStats
            let delta: Decimal
            if let previousStats, previousStats.since == currentStats.since {
                delta = max(currentStats.total.credit - previousStats.total.credit, .zero)
            } else {
                // A changed `since` means the gateway process restarted. The
                // new process starts at zero, so its current total is a new epoch.
                delta = max(currentStats.total.credit, .zero)
            }
            if delta > 0 {
                let day = calendar.startOfDay(for: snapshot.fetchedAt)
                let existing = try repository.dailyUsage(accountID: account.id, limit: nil)
                    .first(where: { calendar.isDate($0.day, inSameDayAs: day) })
                let amount = (existing?.spend?.currency == .cny ? existing?.spend?.amount : nil) ?? .zero
                dailyRecord = DailyUsageRecord(
                    accountID: account.id,
                    day: day,
                    spend: MoneyValue(amount: amount + delta, currency: .cny),
                    updatedAt: snapshot.fetchedAt
                )
            }
        } else if account.providerKind != .workbuddy2api {
            let historyCalendar = account.providerKind == .deepseek
                ? DeepSeekUsageService.historyCalendar
                : calendar
            let day = historyCalendar.startOfDay(for: snapshot.fetchedAt)
            dailyRecord = DailyUsageRecord(accountID: account.id, day: day, spend: snapshot.todaySpend, updatedAt: snapshot.fetchedAt)
        }

        // The cumulative baseline must advance only when its delta is persisted.
        try Task.checkCancellation()
        // Main-actor validation + commit has no suspension: edits/deletion cannot race the write.
        guard scheduler.hasInterestedSubscribers(accountID: account.id),
              let current = try repository.account(id: account.id), current.isEnabled,
              current == account else { throw CancellationError() }
        try repository.commitRefresh(snapshot, dailyUsage: dailyRecord)

        // Initial setup and explicit backfills own historical ranges. Regular
        // refreshes persist only today's data to avoid repeated history traffic.
        return snapshot
    }

    /// Coalesce repeated clicks for an account. Results commit once, after all
    /// requested dates finish, and never change the snapshot or today's record.
    public func startHistoryBackfill(accountID: UUID, days: Int) {
        guard historyBackfillTasks[accountID] == nil else { return }
        let count = days == 30 ? 30 : 7
        do {
            guard let account = try repository.account(id: accountID), account.isEnabled else {
                publishHistory(accountID, HistoryBackfillState(requestedDays: count, phase: .unavailable,
                    message: "账户已停用或已移除，无法回填。")); return
            }
            guard account.providerKind == .pipio || account.providerKind == .deepseek else {
                publishHistory(accountID, HistoryBackfillState(requestedDays: count, phase: .unavailable,
                    message: "网关仅能记录 Relay 已观察到的刷新增量，无法恢复未采集的历史。")); return
            }
            let token = UUID()
            publishHistory(accountID, HistoryBackfillState(requestedDays: count))
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.performHistoryBackfill(account: account, days: count)
                if self.historyBackfillTasks[accountID]?.0 == token { self.historyBackfillTasks.removeValue(forKey: accountID) }
            }
            historyBackfillTasks[accountID] = (token, task)
        } catch {
            publishHistory(accountID, HistoryBackfillState(requestedDays: count, phase: .failed,
                message: "本地存储不可用，未执行历史查询。"))
        }
    }

    public func cancelHistoryBackfill(accountID: UUID) {
        historyBackfillTasks[accountID]?.1.cancel()
        if var state = historyBackfillStates[accountID], state.isActive {
            state.phase = .cancelling; state.message = "正在取消，已保存的历史保持不变。"
            publishHistory(accountID, state)
        }
    }

    public func cancelAllHistoryBackfills() {
        for id in Array(historyBackfillTasks.keys) { cancelHistoryBackfill(accountID: id) }
    }

    private func publishHistory(_ id: UUID, _ state: HistoryBackfillState) {
        historyBackfillStates[id] = state; onHistoryBackfillChange?(id, state)
    }

    private func performHistoryBackfill(account: AccountConfiguration, days: Int) async {
        var state = HistoryBackfillState(requestedDays: days)
        do {
            let credential = try await credentialStore.read(reference: account.credentialReference)
            if account.providerKind == .deepseek,
               credential.deepSeekUserToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                state.phase = .unavailable
                state.message = "DeepSeek 历史需要手动填写平台 userToken；API Key 仅支持余额查询。"
                publishHistory(account.id, state); return
            }
            let adapter = try adapters.adapter(for: account.providerKind)
            let historyCalendar = account.providerKind == .deepseek ? DeepSeekUsageService.historyCalendar : calendar
            let today = historyCalendar.startOfDay(for: clock.now())
            let oldest = historyCalendar.date(byAdding: .day, value: -(days - 1), to: today)!
            let persistedRate = try repository.snapshot(accountID: account.id)?.rate
            var records: [String: DailyUsageRecord] = [:]
            var resolvedRate: AccountRate?
            if account.providerKind == .deepseek {
                state.phase = .running
                state.message = "正在查询近 \(days) 日平台历史；今天由正常刷新更新。"
                publishHistory(account.id, state)
                let fetched = try await fetchHistoryRange(account: account, credential: credential, adapter: adapter,
                    persistedRate: persistedRate, endingAt: today, days: days, calendar: historyCalendar)
                try Task.checkCancellation()
                for record in fetched {
                    let day = historyCalendar.startOfDay(for: record.day)
                    guard record.accountID == account.id, day >= oldest, day < today, let spend = record.spend, !spend.amount.isNaN, spend.amount >= 0 else { continue }
                    let normalized = DailyUsageRecord(accountID: account.id, day: day, spend: spend, updatedAt: clock.now())
                    records[normalized.id] = normalized
                }
                state.processedDays = days - 1; state.availableDays = records.count
                publishHistory(account.id, state)
            } else {
            for offset in 1..<days {
                try Task.checkCancellation()
                guard let current = try repository.account(id: account.id), current == account, current.isEnabled else { throw CancellationError() }
                let day = historyCalendar.date(byAdding: .day, value: -offset, to: today)!
                state.phase = .running
                state.message = "查询已完成日期 \(offset)/\(days - 1)；今天由正常刷新更新。"
                publishHistory(account.id, state)
                let fetched = try await fetchHistoryDay(account: account, credential: credential, adapter: adapter,
                    persistedRate: persistedRate, resolvedRate: &resolvedRate, day: day, calendar: historyCalendar)
                try Task.checkCancellation()
                for record in fetched {
                    let normalizedDay = historyCalendar.startOfDay(for: record.day)
                    guard record.accountID == account.id, normalizedDay >= oldest, normalizedDay < today,
                          normalizedDay == day, let spend = record.spend, !spend.amount.isNaN, spend.amount >= 0 else { continue }
                    let normalized = DailyUsageRecord(accountID: account.id, day: normalizedDay,
                        spend: spend, updatedAt: clock.now())
                    records[normalized.id] = normalized
                }
                state.processedDays = offset; state.availableDays = records.count
                publishHistory(account.id, state)
            }
            }
            try Task.checkCancellation()
            guard let current = try repository.account(id: account.id), current == account, current.isEnabled else { throw CancellationError() }
            if !records.isEmpty { try repository.commitDailyUsage(Array(records.values)) }
            state.phase = .completed
            state.message = "已检查 \(days - 1) 个已完成日期，取得 \(records.count) 天有效金额；缺失日期仍为未知。"
            publishHistory(account.id, state)
            onHistoryBackfillCommit?(account.id)
        } catch {
            if Task.isCancelled || error is CancellationError {
                state.phase = .cancelled; state.message = "已取消，已保存的历史保持不变。"
            } else {
                state.phase = .failed
                state.message = error is LocalRepositoryError ? "历史保存失败，原有数据保持不变。" : "历史查询失败，原有数据保持不变。请检查凭据或稍后重试。"
            }
            publishHistory(account.id, state)
        }
    }

    private func fetchHistoryRange(account: AccountConfiguration, credential: ProviderCredential,
        adapter: any ProviderAdapter, persistedRate: AccountRate?, endingAt: Date, days: Int,
        calendar: Calendar) async throws -> [DailyUsageRecord] {
        for attempt in 0...maxRetryCount {
            try await historyRequestGate.acquire(account.siteOrigin)
            do {
                let rate = try await rateService.resolve(account: account, credential: credential,
                    adapter: adapter, persistedRate: persistedRate, forceRefresh: false, now: clock.now()).rate
                try Task.checkCancellation()
                let result = try await adapter.fetchDailyUsage(for: account, credential: credential,
                    rate: rate, endingAt: endingAt, days: days, calendar: calendar)
                historyRequestGate.release(account.siteOrigin)
                return result
            } catch {
                let providerError = sanitized(error)
                if case .rateLimited(let retryAfter) = providerError {
                    let until = scheduler.recordRateLimit(for: account.siteOrigin, retryAfter: retryAfter)
                    historyRequestGate.recordRateLimit(account.siteOrigin, until: until)
                }
                historyRequestGate.release(account.siteOrigin)
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                guard attempt < maxRetryCount, isRetryable(providerError) else { throw error }
                try await clock.sleep(retryDelay(for: providerError, attempt: attempt))
            }
        }
        return []
    }

    private func fetchHistoryDay(account: AccountConfiguration, credential: ProviderCredential,
        adapter: any ProviderAdapter, persistedRate: AccountRate?, resolvedRate: inout AccountRate?,
        day: Date, calendar: Calendar) async throws -> [DailyUsageRecord] {
        for attempt in 0...maxRetryCount {
            try await historyRequestGate.acquire(account.siteOrigin)
            do {
                if resolvedRate == nil {
                    resolvedRate = try await rateService.resolve(account: account, credential: credential,
                        adapter: adapter, persistedRate: persistedRate, forceRefresh: false, now: clock.now()).rate
                }
                try Task.checkCancellation()
                let endingAt = account.providerKind == .pipio ? calendar.date(byAdding: .day, value: 1, to: day)! : day
                let result = try await adapter.fetchDailyUsage(for: account, credential: credential,
                    rate: resolvedRate!, endingAt: endingAt, days: account.providerKind == .pipio ? 2 : 1, calendar: calendar)
                historyRequestGate.release(account.siteOrigin)
                return result
            } catch {
                let providerError = sanitized(error)
                if case .rateLimited(let retryAfter) = providerError {
                    let until = scheduler.recordRateLimit(for: account.siteOrigin, retryAfter: retryAfter)
                    historyRequestGate.recordRateLimit(account.siteOrigin, until: until)
                }
                historyRequestGate.release(account.siteOrigin)
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                guard attempt < maxRetryCount, isRetryable(providerError) else { throw error }
                try await clock.sleep(retryDelay(for: providerError, attempt: attempt))
            }
        }
        return []
    }

    private func isRetryable(_ error: ProviderError) -> Bool {
        switch error {
        case .transport, .rateLimited: return true
        case .server(let status): return status >= 500 && status < 600
        default: return false
        }
    }

    private func retryDelay(for error: ProviderError, attempt: Int) -> TimeInterval {
        if case .rateLimited(let retryAfter) = error, let retryAfter {
            return RefreshScheduler.safeRetryDelay(retryAfter)
        }
        return min(pow(2, Double(attempt + 1)), 30)
    }

    private func sanitized(_ error: Error) -> ProviderError {
        if let providerError = error as? ProviderError { return providerError }
        if let usageError = error as? DeepSeekUsageServiceError {
            switch usageError {
            case .invalidUserToken, .userTokenUnauthorized: return .invalidCredential
            case .invalidDateRange, .rangeTooLarge, .invalidResponse: return .incompatibleResponse
            }
        }
        if error is LocalRepositoryError { return .storageUnavailable }
        if let credentialError = error as? CredentialStoreError {
            return credentialError == .notFound ? .invalidCredential : .storageUnavailable
        }
        return .transport
    }
}
