import Foundation

@MainActor
private final class OrderingRepository: LocalRepository {
    let underlying = InMemoryLocalRepository()
    var failReplace = false
    var rejectCompareAndSwap = false
    var replacements = 0
    func fetchAccounts() throws -> [AccountConfiguration] { try underlying.fetchAccounts() }
    func account(id: UUID) throws -> AccountConfiguration? { try underlying.account(id: id) }
    func upsertAccount(_ account: AccountConfiguration) throws { try underlying.upsertAccount(account) }
    func deleteAccount(id: UUID) throws { try underlying.deleteAccount(id: id) }
    func snapshot(accountID: UUID) throws -> ProviderSnapshot? { try underlying.snapshot(accountID: accountID) }
    func upsertSnapshot(_ snapshot: ProviderSnapshot) throws { try underlying.upsertSnapshot(snapshot) }
    func commitRefresh(_ snapshot: ProviderSnapshot, dailyUsage: DailyUsageRecord?) throws { try underlying.commitRefresh(snapshot, dailyUsage: dailyUsage) }
    func dailyUsage(accountID: UUID, limit: Int?) throws -> [DailyUsageRecord] { try underlying.dailyUsage(accountID: accountID, limit: limit) }
    func upsertDailyUsage(_ record: DailyUsageRecord) throws { try underlying.upsertDailyUsage(record) }
    func settings() throws -> RelaySettings { try underlying.settings() }
    func updateSettings(_ settings: RelaySettings) throws { try underlying.updateSettings(settings) }
    func syncData() throws -> RelaySyncData { try underlying.syncData() }
    func mergeSyncData(_ data: RelaySyncData) throws { try underlying.mergeSyncData(data) }
    func replaceNonsecretData(_ data: RelaySyncData, expected: RelaySyncData) throws -> Bool {
        replacements += 1
        if failReplace { throw LocalRepositoryError.unavailable }
        if rejectCompareAndSwap { return false }
        return try underlying.replaceNonsecretData(data, expected: expected)
    }
}

@MainActor
enum AccountOrderingChecks {
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain: "AccountOrderingChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    private static func rejects(_ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw NSError(domain: "AccountOrderingChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid ordering unexpectedly committed"])
    }
    private static func makeStore(_ repository: any LocalRepository) -> RelayStore {
        RelayStore(repository: repository, credentialStore: InMemoryCredentialStore(), adapters: .init(adapters: []), automaticallyRefresh: false)
    }

    static func run() throws {
        let repository = OrderingRepository()
        let epoch = Date(timeIntervalSince1970: 1000)
        let future = Date().addingTimeInterval(3600)
        let first = AccountConfiguration(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, displayName: "First", providerKind: .pipio,
            siteOrigin: URL(string: "https://first.invalid")!, credentialReference: "private-first", isPinned: true, sortOrder: 0, createdAt: epoch, updatedAt: future)
        let second = AccountConfiguration(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, displayName: "Second", providerKind: .pipio,
            siteOrigin: URL(string: "https://second.invalid")!, credentialReference: "private-second", isEnabled: false, isHidden: true,
            monthlyBudget: .init(amount: 50, currency: .cny), groupName: "Work", sortOrder: 0, createdAt: epoch, updatedAt: future)
        let third = AccountConfiguration(displayName: "Gateway", providerKind: .workbuddy2api,
            siteOrigin: URL(string: "https://gateway.invalid")!, sortOrder: 9, createdAt: epoch.addingTimeInterval(1), updatedAt: future)
        for account in [third, second, first] { try repository.upsertAccount(account) }
        let removed = AccountConfiguration(displayName: "Removed", providerKind: .pipio, siteOrigin: URL(string: "https://removed.invalid")!)
        try repository.upsertAccount(removed)
        try repository.deleteAccount(id: removed.id)
        let rate = AccountRate(accountID: first.id, source: .providerNativeCurrency, nativeCurrency: .cny)
        let snapshot = ProviderSnapshot(accountID: first.id, balance: .init(amount: 50, currency: .cny), todaySpend: nil,
            monthSpend: nil, requestCount: nil, capabilities: [.balance], freshness: .fresh, rate: rate)
        try repository.upsertSnapshot(snapshot)
        try repository.upsertDailyUsage(.init(accountID: first.id, day: Date(), spend: .init(amount: 2, currency: .cny)))
        let store = makeStore(repository)
        let initial = try repository.syncData()
        try require(AccountOrganizationService.manualOrder(initial.accounts).map(\.id) == [first.id, second.id, third.id], "Legacy tied orders are deterministic")
        try store.reorderAccounts([first.id, second.id, third.id])
        try require(repository.replacements == 0, "No-op order does not write or bump timestamps")
        try rejects { try store.reorderAccounts([first.id, first.id, third.id]) }
        try rejects { try store.reorderAccounts([first.id, third.id]) }
        try rejects { try store.reorderAccounts([first.id, UUID(), third.id]) }
        try rejects { try store.reorderAccounts([]) }
        try require(try repository.syncData().hasSameContent(as: initial), "Invalid or stale membership rejects the whole change")

        let target = [third.id, second.id, first.id]
        repository.failReplace = true
        try rejects { try store.reorderAccounts(target) }
        try require(try repository.syncData().hasSameContent(as: initial), "Write failure leaves all metadata and history intact")
        try require(store.accountConfiguration(id: third.id)?.sortOrder == 9, "Failed write does not publish a new order")
        repository.failReplace = false
        repository.rejectCompareAndSwap = true
        try rejects { try store.reorderAccounts(target) }
        try require(try repository.syncData().hasSameContent(as: initial), "CAS rejection leaves all data intact")
        repository.rejectCompareAndSwap = false
        let beforeWrites = repository.replacements
        try store.reorderAccounts(target)
        try require(repository.replacements == beforeWrites + 1, "A reorder uses one atomic write")
        let after = try repository.syncData()
        let ordered = AccountOrganizationService.manualOrder(after.accounts)
        try require(ordered.map(\.id) == target && ordered.map(\.sortOrder) == [0, 1, 2], "Ordering is saved with bounded contiguous ranks")
        for original in initial.accounts {
            var changed = after.accounts.first { $0.id == original.id }!
            try require(changed.updatedAt > original.updatedAt, "Future timestamps advance monotonically for sync")
            changed.sortOrder = original.sortOrder
            changed.updatedAt = original.updatedAt
            try require(changed == original, "Order does not alter credentials, pin, group, visibility, budget, or identity")
        }
        try require(after.snapshots == initial.snapshots && after.dailyUsage == initial.dailyUsage && after.settings == initial.settings
            && after.settingsUpdatedAt == initial.settingsUpdatedAt && after.deletedAccountIDs == initial.deletedAccountIDs, "Non-account state is unchanged")
        let home = AccountOrganizationService.sorted(store.accounts, configurations: store.accountConfigurations)
        try require(home.first?.id == first.id.uuidString, "Home retains pin precedence over manual order")
        try require(store.accounts.map(\.id) == target.map(\.uuidString), "Store publishes persisted manual order")
        let exported = try DataTransferService.exportConfiguration(after)
        let preview = try DataTransferService.previewConfiguration(exported, existingAccountIDs: Set(target))
        try require(AccountOrganizationService.manualOrder(preview.archive.accounts).map(\.id) == target, "Order survives portable configuration export/import")
        let backup = try DataTransferService.decodeBackup(DataTransferService.exportBackup(after))
        try require(AccountOrganizationService.manualOrder(backup.accounts).map(\.id) == target, "Order survives backup encoding")
        let synced = RelaySyncDataSafety.sanitized(after)
        try require(AccountOrganizationService.manualOrder(synced.accounts).map(\.id) == target, "Order survives sync projection")
        try store.reorderAccounts([second.id, first.id, third.id])
        try require(store.accountConfiguration(id: second.id)?.sortOrder == 0, "Repeated adjacent reorder works for hidden/disabled accounts")
        let boundary = OrderingRepository()
        let boundaryStore = makeStore(boundary)
        try boundaryStore.reorderAccounts([])
        try require(boundary.replacements == 0, "Empty list is a no-op")
        try boundary.upsertAccount(first)
        try boundaryStore.reorderAccounts([first.id])
        try require(boundary.replacements == 0, "Single-account order is a no-op")
        try boundary.upsertAccount(second)
        try rejects { try boundaryStore.reorderAccounts([first.id]) }
        try boundary.deleteAccount(id: first.id)
        try rejects { try boundaryStore.reorderAccounts([first.id, second.id]) }
        try require(boundary.replacements == 0, "Concurrent add/delete invalidates stale membership")
        print("PASSED: account ordering validation, no-op, atomic write/failure, CAS, metadata preservation, pin precedence and transfer compatibility")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-ordering-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("local.json")
        let disk = try FileLocalRepository(fileURL: fileURL)
        for account in [first, second, third] { try disk.upsertAccount(account) }
        try makeStore(disk).reorderAccounts(target)
        let reopened = try FileLocalRepository(fileURL: fileURL)
        try require(try reopened.fetchAccounts().map(\.id) == target, "Manual order survives repository reopen")
        print("PASSED: account ordering persists after disk reopen")
    }
}
