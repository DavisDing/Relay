import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CheckFailure(description: message) }
}

@MainActor
private func rejects(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw CheckFailure(description: "Expected failure: " + message)
}

@MainActor
private func rejectsAsync(_ message: String, _ body: () async throws -> Void) async throws {
    do { try await body() } catch { return }
    throw CheckFailure(description: "Expected failure: " + message)
}

private let placeholder = ProviderCredential(secret: "test-placeholder-not-a-real-secret", pipioUserID: "1")
private let replacement = ProviderCredential(secret: "test-replacement-not-a-real-secret", pipioUserID: "2")

private struct StubAdapter: ProviderAdapter {
    let kind: ProviderKind = .pipio
    func fetchAccountRate(for account: AccountConfiguration, credential: ProviderCredential) async throws -> AccountRate {
        AccountRate(accountID: account.id, source: .providerNativeCurrency, nativeCurrency: .cny)
    }
    func validateAccount(_ account: AccountConfiguration, credential: ProviderCredential) async throws {}
    func fetchSnapshot(for account: AccountConfiguration, credential: ProviderCredential, rate: AccountRate, now: Date, calendar: Calendar) async throws -> ProviderSnapshot {
        snapshot(account.id, at: now)
    }
}

private func snapshot(_ id: UUID, at date: Date, spend: Decimal? = 42) -> ProviderSnapshot {
    ProviderSnapshot(accountID: id, balance: MoneyValue(amount: 100, currency: .cny),
                     todaySpend: spend.map { MoneyValue(amount: $0, currency: .cny) }, monthSpend: nil,
                     requestCount: nil, capabilities: [.balance, .todayUsage], freshness: .fresh,
                     fetchedAt: date, rate: AccountRate(accountID: id, source: .providerNativeCurrency, nativeCurrency: .cny, fetchedAt: date))
}

private func account(_ name: String, at date: Date = Date()) -> AccountConfiguration {
    AccountConfiguration(displayName: name, providerKind: .pipio,
                         siteOrigin: URL(string: "https://example.invalid")!, createdAt: date, updatedAt: date)
}

private func encoded(_ data: RelaySyncData) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(data)
}

private func decoded(_ data: Data) throws -> RelaySyncData {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(RelaySyncData.self, from: data)
}

/// The failure is injected AFTER successful setup, never by altering assertions.
@MainActor
private final class RejectingRepository: LocalRepository {
    let base = InMemoryLocalRepository()
    var rejectWrites = false
    func fetchAccounts() throws -> [AccountConfiguration] { try base.fetchAccounts() }
    func account(id: UUID) throws -> AccountConfiguration? { try base.account(id: id) }
    func upsertAccount(_ account: AccountConfiguration) throws {
        if rejectWrites { throw LocalRepositoryError.unavailable }
        try base.upsertAccount(account)
    }
    func deleteAccount(id: UUID) throws { try base.deleteAccount(id: id) }
    func snapshot(accountID: UUID) throws -> ProviderSnapshot? { try base.snapshot(accountID: accountID) }
    func upsertSnapshot(_ snapshot: ProviderSnapshot) throws { try base.upsertSnapshot(snapshot) }
    func dailyUsage(accountID: UUID, limit: Int?) throws -> [DailyUsageRecord] { try base.dailyUsage(accountID: accountID, limit: limit) }
    func upsertDailyUsage(_ record: DailyUsageRecord) throws { try base.upsertDailyUsage(record) }
    func settings() throws -> RelaySettings { try base.settings() }
    func updateSettings(_ settings: RelaySettings) throws {
        if rejectWrites { throw LocalRepositoryError.unavailable }
        try base.updateSettings(settings)
    }
    func syncData() throws -> RelaySyncData { try base.syncData() }
    func mergeSyncData(_ data: RelaySyncData) throws { try base.mergeSyncData(data) }
}

private actor FaultyCredentials: CredentialStore {
    var saved: ProviderCredential?
    let rejectRead: Bool
    let rejectRollback: Bool
    init(rejectRead: Bool = false, rejectRollback: Bool = false) {
        self.rejectRead = rejectRead
        self.rejectRollback = rejectRollback
    }
    func read(reference: String) async throws -> ProviderCredential {
        if rejectRead { throw CredentialStoreError.decodingFailed }
        guard let saved else { throw CredentialStoreError.notFound }
        return saved
    }
    func save(_ credential: ProviderCredential, reference: String) async throws { saved = credential }
    func delete(reference: String) async throws {
        if rejectRollback { throw CredentialStoreError.writeFailed }
        saved = nil
    }
    func hasSaved() -> Bool { saved != nil }
}

@main
struct RegressionChecks {
    @MainActor static func main() async {
        // Flush each group so a failure retains all preceding test results.
        setbuf(stdout, nil)
        do { try await run() }
        catch {
            fputs("FAILED: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-fixtures-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try BusinessLogicSelfCheck.run()
        print("PASSED: existing business logic self-check")
        try await PipioDashboardContractChecks.run()
        try MenuBarPresentationChecks.run()
        try await AccountFeedbackChecks.run()
        try await credentials(root)
        print("PASSED: credential load failure, retry, atomic write and permissions")
        try repositoryTransactions(root)
        print("PASSED: all repository writes preserve state on failure")
        try await accountEditing()
        print("PASSED: imported credential entry, replacement and rollback errors")
        try await manualExchangeRates(root)
        print("PASSED: manual FX validation, offline totals, isolation, rollback, persistence and sync")
        try mergeRules()
        print("PASSED: deterministic merge, timestamp ties and legacy JSON")
        try fileExchange(root)
        print("PASSED: two-device exchange, deletion and damaged file protection")
        try presentation()
        print("PASSED: enabled-account coverage, midnight/timezone invalidation and settings failure")
        print("PASSED: all regression groups (temporary fixtures, no provider requests)")
    }

    @MainActor static func credentials(_ root: URL) async throws {
        let manager = FileManager.default
        let url = root.appendingPathComponent("private/credentials.json")
        let store = FileCredentialStore(fileURL: url)
        try await store.save(placeholder, reference: "existing")
        let saved = try await store.read(reference: "existing")
        try check(saved == placeholder, "new store must persist first credential")
        let fileMode = try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        let directoryMode = try manager.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        try check(fileMode?.intValue == 0o600 && directoryMode?.intValue == 0o700, "private permissions")
        let original = try Data(contentsOf: url)
        // An existing directory cannot be atomically replaced with a regular file.
        let backup = url.appendingPathExtension("backup")
        try manager.moveItem(at: url, to: backup)
        try manager.createDirectory(at: url, withIntermediateDirectories: false)
        try await rejectsAsync("failed credential save") { try await store.save(replacement, reference: "existing") }
        try await rejectsAsync("failed credential delete") { try await store.delete(reference: "existing") }
        let afterFailure = try await store.read(reference: "existing")
        try check(afterFailure == placeholder, "failed writes must not mutate credential cache")
        try check(try Data(contentsOf: backup) == original, "failed writes must preserve prior bytes")
        try manager.removeItem(at: url)
        try manager.moveItem(at: backup, to: url)
        try await store.save(replacement, reference: "other")
        let reopened = FileCredentialStore(fileURL: url)
        let retained = try await reopened.read(reference: "existing")
        try check(retained == placeholder, "later success must not commit earlier failed change")

        for (index, bytes) in [Data("not-json".utf8), Data("{\"schemaVersion\":999,\"values\":{}}".utf8)].enumerated() {
            let damagedURL = root.appendingPathComponent("damaged-\(index)/credentials.json")
            try manager.createDirectory(at: damagedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: damagedURL)
            let damaged = FileCredentialStore(fileURL: damagedURL)
            try await rejectsAsync("corrupt/unknown initial read") { _ = try await damaged.read(reference: "existing") }
            try await rejectsAsync("save after failed load") { try await damaged.save(replacement, reference: "new") }
            try await rejectsAsync("delete after failed load") { try await damaged.delete(reference: "existing") }
            try check(try Data(contentsOf: damagedURL) == bytes, "unreadable credential file must not be overwritten")
            try original.write(to: damagedURL)
            let recovered = try await damaged.read(reference: "existing")
            try check(recovered == placeholder, "failed load must be retryable after file repair")
        }
    }

    @MainActor static func repositoryTransactions(_ root: URL) throws {
        let manager = FileManager.default
        let url = root.appendingPathComponent("repository/local.json")
        let repo = try FileLocalRepository(fileURL: url)
        let a = account("original")
        let snap = snapshot(a.id, at: Date())
        let usage = DailyUsageRecord(accountID: a.id, day: Calendar.current.startOfDay(for: Date()), spend: snap.todaySpend)
        try repo.upsertAccount(a)
        try repo.upsertSnapshot(snap)
        try repo.upsertDailyUsage(usage)
        let before = try repo.syncData()
        let beforeBytes = try Data(contentsOf: url)
        let backup = url.appendingPathExtension("backup")
        try manager.moveItem(at: url, to: backup)
        try manager.createDirectory(at: url, withIntermediateDirectories: false)
        let added = account("must not appear")
        var settings = try repo.settings()
        settings.refreshIntervalSeconds = 900
        try rejects("account save") { try repo.upsertAccount(added) }
        try rejects("snapshot save") { try repo.upsertSnapshot(snapshot(a.id, at: Date(), spend: 99)) }
        try rejects("daily save") { try repo.upsertDailyUsage(DailyUsageRecord(accountID: a.id, day: usage.day, spend: nil)) }
        try rejects("settings save") { try repo.updateSettings(settings) }
        try rejects("account deletion") { try repo.deleteAccount(id: a.id) }
        try rejects("sync merge") { try repo.mergeSyncData(RelaySyncData(accounts: [added], snapshots: [], dailyUsage: [], settings: settings)) }
        let after = try repo.syncData()
        try check(after.accounts == before.accounts && after.snapshots == before.snapshots && after.dailyUsage == before.dailyUsage, "failed writes must not change records")
        try check(after.settings == before.settings && after.settingsUpdatedAt == before.settingsUpdatedAt && after.deletedAccountIDs == before.deletedAccountIDs, "failed writes must not change settings or tombstones")
        try check(try Data(contentsOf: backup) == beforeBytes, "failed mutations preserve disk bytes")
        try manager.removeItem(at: url)
        try manager.moveItem(at: backup, to: url)
        try repo.updateSettings(settings)
        let reopened = try FileLocalRepository(fileURL: url)
        try check(try reopened.account(id: added.id) == nil, "later save must not commit previously failed insertion")
        try check(try reopened.snapshot(accountID: a.id)?.todaySpend == snap.todaySpend, "later save must not commit previously failed snapshot")
        try check(try reopened.account(id: a.id) != nil, "failed delete must not become persistent")
        let mode = try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        try check(mode?.intValue == 0o600, "repository file permissions")
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        legacy.removeValue(forKey: "settingsUpdatedAt")
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)
        let legacyRepo = try FileLocalRepository(fileURL: url)
        try check(try legacyRepo.account(id: a.id) != nil, "legacy local JSON remains readable")
    }

    @MainActor static func manualExchangeRates(_ root: URL) async throws {
        try check(try USDToCNYRate.parseOverride(" 7.30 ") == Decimal(string: "7.3"), "positive manual FX")
        try check(try USDToCNYRate.parseOverride("  ") == nil, "blank restores automatic FX")
        for text in ["0", "-1", "nan", "inf", "7.3abc", "7,3", "7 3", "1e2", "7.3.1", ".", String(repeating: "9", count: 200)] {
            do {
                _ = try USDToCNYRate.parseOverride(text)
                throw CheckFailure(description: "invalid FX accepted: \(text)")
            } catch AccountServiceError.invalidExchangeRate {}
        }

        let repo = RejectingRepository()
        let a = account("manual FX")
        try repo.upsertAccount(a)
        let now = Date()
        func usdSnapshot(_ id: UUID, fx: Decimal?, expired: Bool = false) -> ProviderSnapshot {
            ProviderSnapshot(accountID: id, balance: MoneyValue(amount: 10, currency: .usd),
                todaySpend: MoneyValue(amount: 2, currency: .usd), monthSpend: nil, requestCount: nil,
                capabilities: [.balance, .todayUsage], freshness: .fresh, fetchedAt: now,
                rate: AccountRate(accountID: id, source: .pipioAccountStatus, nativeCurrency: .usd,
                    quotaPerUnit: 500000, conversionToCNY: fx, fetchedAt: now,
                    expiresAt: expired ? now.addingTimeInterval(-1) : now.addingTimeInterval(3600)))
        }
        let raw = usdSnapshot(a.id, fx: nil)
        try repo.upsertSnapshot(raw)
        // Empty registry and credential store prove metadata edits do not request a provider.
        let credentials = InMemoryCredentialStore()
        let store = RelayStore(repository: repo, credentialStore: credentials,
            adapters: ProviderAdapterRegistry(adapters: []), automaticallyRefresh: false)
        try check(store.balanceTotalCNY.value == nil, "missing site FX stays unknown")
        try await store.updateAccount(accountID: a.id, displayName: a.displayName,
            lowBalanceThreshold: 20, manualUSDToCNY: .set(7))
        try check(store.balanceTotalCNY.value?.amount == 70 && store.todaySpendTotalCNY.value?.amount == 14,
            "offline manual FX immediately updates home/menu totals")
        try check(store.accounts[0].manualUSDToCNY == 7 && store.accounts[0].quotaPerUnit == 500000,
            "edit projection separates manual FX and site quota")
        try check(try repo.snapshot(accountID: a.id) == raw, "manual FX never rewrites native amounts or quota")
        try await store.updateAccount(accountID: a.id, displayName: "renamed", lowBalanceThreshold: 15)
        try check(try repo.account(id: a.id)?.manualUSDToCNY == 7, "unrelated edits preserve override")
        let saved = try repo.account(id: a.id)!
        for invalid in [Decimal.zero, Decimal(-1), Decimal.nan] {
            do {
                try await store.updateAccount(accountID: a.id, displayName: "invalid", lowBalanceThreshold: 20,
                    replacementCredential: placeholder, manualUSDToCNY: .set(invalid))
                throw CheckFailure(description: "invalid business-layer FX accepted")
            } catch AccountServiceError.invalidExchangeRate {}
        }
        try check(try repo.account(id: a.id) == saved, "invalid FX is atomic and validated before credential calls")
        repo.rejectWrites = true
        try await rejectsAsync("manual FX write failure") {
            try await store.updateAccount(accountID: a.id, displayName: "rejected", lowBalanceThreshold: 20,
                manualUSDToCNY: .set(9))
        }
        repo.rejectWrites = false
        try check(try repo.account(id: a.id) == saved && store.balanceTotalCNY.value?.amount == 70,
            "failed save preserves override and totals")

        let providerSnapshot = usdSnapshot(a.id, fx: 6)
        let expired = usdSnapshot(a.id, fx: 6, expired: true)
        try check(DashboardAggregator.balanceTotal(snapshots: [providerSnapshot], targetCurrency: .cny,
            manualUSDToCNY: [a.id: 7]).value?.amount == 70, "manual overrides valid provider FX")
        try check(DashboardAggregator.balanceTotal(snapshots: [expired], targetCurrency: .cny,
            manualUSDToCNY: [a.id: 7]).value?.amount == 70, "manual FX does not inherit provider expiry")
        try check(DashboardAggregator.balanceTotal(snapshots: [expired], targetCurrency: .cny).value == nil,
            "automatic mode still rejects expired site FX")
        let other = usdSnapshot(UUID(), fx: nil)
        let isolated = DashboardAggregator.balanceTotal(snapshots: [raw, other], targetCurrency: .cny,
            manualUSDToCNY: [a.id: 7])
        try check(isolated.value?.amount == 70 && isolated.excludedAccountIDs == [other.accountID],
            "manual rate cannot leak to another account")
        try check(DashboardAggregator.balanceTotal(snapshots: [raw], targetCurrency: .usd,
            manualUSDToCNY: [a.id: 7]).value?.amount == 10, "native USD remains unchanged")
        try check(DashboardAggregator.balanceTotal(snapshots: [snapshot(a.id, at: now)], targetCurrency: .cny,
            manualUSDToCNY: [a.id: 7]).value?.amount == 100, "native CNY is not multiplied")
        try check(DashboardAggregator.balanceTotal(snapshots: [raw], targetCurrency: .cny,
            manualUSDToCNY: [a.id: .nan]).value == nil, "invalid imported override never produces fake total")
        try await store.updateAccount(accountID: a.id, displayName: "automatic", lowBalanceThreshold: 20,
            manualUSDToCNY: .set(nil))
        try check(store.balanceTotalCNY.value == nil, "clearing with no site FX restores unknown")
        try repo.upsertSnapshot(providerSnapshot)
        try await store.updateAccount(accountID: a.id, displayName: "automatic", lowBalanceThreshold: 20)
        try check(store.balanceTotalCNY.value?.amount == 60, "clearing restores site FX")

        let file = root.appendingPathComponent("manual-fx.json")
        let disk = try FileLocalRepository(fileURL: file)
        try disk.upsertAccount(saved)
        let restarted = try FileLocalRepository(fileURL: file)
        try check(try restarted.account(id: a.id)?.manualUSDToCNY == 7, "manual FX survives restart")
        let safePayload = RelaySyncDataSafety.sanitized(try restarted.syncData())
        let imported = InMemoryLocalRepository()
        try imported.mergeSyncData(try decoded(encoded(safePayload)))
        try check(try imported.account(id: a.id)?.manualUSDToCNY == 7, "safe sync projection retains manual FX")
        var hidden = saved
        hidden.isHidden = true
        try check(RelaySyncDataSafety.sanitized(RelaySyncData(accounts: [hidden], snapshots: [], dailyUsage: [], settings: RelaySettings())).accounts.first?.isHidden == true, "safe sync projection retains hidden preference")
        // Decode a record written before this optional field existed.
        var oldObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        oldObject.removeValue(forKey: "manualUSDToCNY")
        let old = try JSONDecoder().decode(AccountConfiguration.self, from: JSONSerialization.data(withJSONObject: oldObject))
        oldObject.removeValue(forKey: "isHidden")
        let legacy = try JSONDecoder().decode(AccountConfiguration.self, from: JSONSerialization.data(withJSONObject: oldObject))
        try check(old.manualUSDToCNY == nil && old.id == saved.id && !legacy.isHidden, "legacy account JSON remains readable with hidden default")
        try disk.upsertAccount(try repo.account(id: a.id)!)
        try imported.mergeSyncData(try decoded(encoded(RelaySyncDataSafety.sanitized(disk.syncData()))))
        try check(try imported.account(id: a.id)?.manualUSDToCNY == nil, "newer clear synchronizes automatic mode")
    }

    @MainActor static func accountEditing() async throws {
        let repo = RejectingRepository()
        let a = account("imported")
        try repo.upsertAccount(a)
        let creds = InMemoryCredentialStore()
        let registry = ProviderAdapterRegistry(adapters: [StubAdapter()])
        let service = AccountService(repository: repo, credentialStore: creds, adapters: registry)
        try await service.updateAccount(accountID: a.id, displayName: "ready", lowBalanceThreshold: 20, replacementCredential: placeholder)
        let entered = try await creds.read(reference: a.credentialReference)
        try check(entered == placeholder && repo.account(id: a.id)?.displayName == "ready", "imported account must accept new credentials")
        repo.rejectWrites = true
        try await rejectsAsync("metadata save rolls back replacement") {
            try await service.updateAccount(accountID: a.id, displayName: "failed", lowBalanceThreshold: 20, replacementCredential: replacement)
        }
        let restored = try await creds.read(reference: a.credentialReference)
        try check(restored == placeholder, "replacement rollback restores previous credential")
        try await creds.delete(reference: a.credentialReference)
        try await rejectsAsync("new credential rollback") {
            try await service.updateAccount(accountID: a.id, displayName: "failed", lowBalanceThreshold: 20, replacementCredential: replacement)
        }
        try await rejectsAsync("new credential must be removed on metadata failure") { _ = try await creds.read(reference: a.credentialReference) }

        repo.rejectWrites = false
        var gateway = account("gateway")
        gateway.providerKind = .workbuddy2api
        try repo.upsertAccount(gateway)
        try repo.upsertSnapshot(snapshot(gateway.id, at: Date()))
        try await creds.save(placeholder, reference: gateway.credentialReference)
        try await service.deleteAccount(id: gateway.id)
        try check(try repo.account(id: gateway.id) == nil && repo.snapshot(accountID: gateway.id) == nil, "gateway removal clears metadata and snapshot")
        try check(try repo.syncData().deletedAccountIDs[gateway.id] != nil, "gateway removal records sync tombstone")
        try await rejectsAsync("gateway credential must be removed") { _ = try await creds.read(reference: gateway.credentialReference) }
        try repo.upsertAccount(gateway)
        try await service.deleteAccount(id: gateway.id)
        try check(try repo.account(id: gateway.id) == nil, "gateway remains removable with a missing credential")
        repo.rejectWrites = true

        let unreadable = FaultyCredentials(rejectRead: true)
        let unreadableService = AccountService(repository: repo, credentialStore: unreadable, adapters: registry)
        do {
            try await unreadableService.updateAccount(accountID: a.id, displayName: "failed", lowBalanceThreshold: 20, replacementCredential: replacement)
            throw CheckFailure(description: "decoding failure must not be treated as missing credentials")
        } catch CredentialStoreError.decodingFailed {}
        let didSave = await unreadable.hasSaved()
        try check(!didSave, "unreadable store must not be written")
        let failedRollback = FaultyCredentials(rejectRollback: true)
        let rollbackService = AccountService(repository: repo, credentialStore: failedRollback, adapters: registry)
        do {
            try await rollbackService.updateAccount(accountID: a.id, displayName: "failed", lowBalanceThreshold: 20, replacementCredential: replacement)
            throw CheckFailure(description: "rollback failure must surface")
        } catch AccountServiceError.credentialRollbackFailed {}
    }

    @MainActor static func mergeRules() throws {
        let t = Date(timeIntervalSince1970: 1_789_776_000)
        var a = account("A", at: t)
        var b = a
        b.displayName = "B"
        let left = RelaySyncData(exportedAt: t, accounts: [a], snapshots: [snapshot(a.id, at: t)], dailyUsage: [], settings: RelaySettings())
        let right = RelaySyncData(exportedAt: t, accounts: [b], snapshots: [snapshot(a.id, at: t, spend: 8)], dailyUsage: [], settings: RelaySettings(refreshIntervalSeconds: 900))
        let ab = try SyncMerge.merge(left, right)
        let ba = try SyncMerge.merge(right, left)
        try check(ab == ba, "equal timestamps must have order-independent winner")
        try check(try SyncMerge.merge(ab, ab) == ab, "merge must be idempotent")
        let deletion = RelaySyncData(exportedAt: t, accounts: [], snapshots: [], dailyUsage: [], settings: RelaySettings(), deletedAccountIDs: [a.id: t])
        try check(try SyncMerge.merge(left, deletion).accounts.isEmpty, "deletion wins timestamp tie")
        a.updatedAt = t.addingTimeInterval(0.8)
        let fractional = RelaySyncData(accounts: [a], snapshots: [], dailyUsage: [], settings: RelaySettings())
        try check(try SyncMerge.merge(fractional, decoded(encoded(deletion))).accounts.isEmpty, "wire precision must not resurrect same-second deleted account")
        a.updatedAt = t.addingTimeInterval(1)
        let edited = RelaySyncData(accounts: [a], snapshots: [], dailyUsage: [], settings: RelaySettings())
        try check(try SyncMerge.merge(edited, deletion).accounts.count == 1, "genuinely later edit may restore account")
        let newest = RelaySyncData(accounts: [], snapshots: [], dailyUsage: [], settings: RelaySettings(refreshIntervalSeconds: 1800, iCloudFileSyncEnabled: true), settingsUpdatedAt: t)
        let prefs = try SyncMerge.merge(left, newest)
        try check(prefs.settings.refreshIntervalSeconds == 1800, "newest preference timestamp must win")
        try check(!prefs.settings.iCloudFileSyncEnabled, "remote preferences must not opt this device into sync")
        let localEnabled = RelaySyncData(accounts: [], snapshots: [], dailyUsage: [], settings: RelaySettings(iCloudFileSyncEnabled: true))
        try check(try SyncMerge.merge(localEnabled, left).settings.iCloudFileSyncEnabled, "remote sync-off must not disable local sync")
        let newerSnapshot = snapshot(a.id, at: t.addingTimeInterval(10), spend: 99)
        let oldUsage = DailyUsageRecord(accountID: a.id, day: t, spend: MoneyValue(amount: 1, currency: .cny), updatedAt: t)
        let newUsage = DailyUsageRecord(accountID: a.id, day: t, spend: MoneyValue(amount: 2, currency: .cny), updatedAt: t.addingTimeInterval(10))
        let history1 = RelaySyncData(accounts: [a], snapshots: [snapshot(a.id, at: t)], dailyUsage: [oldUsage], settings: RelaySettings())
        let history2 = RelaySyncData(accounts: [a], snapshots: [newerSnapshot], dailyUsage: [newUsage], settings: RelaySettings())
        let history = try SyncMerge.merge(history2, history1)
        try check(history.snapshots == [newerSnapshot] && history.dailyUsage == [newUsage], "old snapshot/history must not overwrite newer records")
        let oldJSON = try encoded(left) // Optional field omitted, as in old schema.
        try check(try decoded(oldJSON).settingsUpdatedAt == nil, "legacy payload without preference timestamp")
        try check(try decoded(encoded(prefs)).settingsUpdatedAt == t, "new optional timestamp round trip")
        let invalid = RelaySyncData(schemaVersion: 999, accounts: [], snapshots: [], dailyUsage: [], settings: RelaySettings())
        try rejects("unsupported sync schema") { _ = try SyncMerge.merge(left, invalid) }
    }

    @MainActor static func fileExchange(_ root: URL) throws {
        let manager = FileManager.default
        let shared = root.appendingPathComponent("shared")
        try manager.createDirectory(at: shared, withIntermediateDirectories: true)
        let a = try FileLocalRepository(fileURL: root.appendingPathComponent("mac-a/local.json"))
        let b = try FileLocalRepository(fileURL: root.appendingPathComponent("mac-b/local.json"))
        let first = account("device A", at: Date().addingTimeInterval(-10))
        let second = account("device B", at: Date().addingTimeInterval(-10))
        try a.upsertAccount(first)
        try a.upsertSnapshot(snapshot(first.id, at: Date()))
        try b.upsertAccount(second)
        try FileSyncService.exchange(repository: a, directory: shared, writeBack: true)
        try FileSyncService.exchange(repository: b, directory: shared, writeBack: true)
        try check(try b.fetchAccounts().count == 2, "export must merge unseen remote account before writing")
        try FileSyncService.exchange(repository: a, directory: shared, writeBack: true)
        try check(try a.fetchAccounts().count == 2, "subsequent exchange must converge")
        let editing = AccountService(repository: a, credentialStore: InMemoryCredentialStore(), adapters: ProviderAdapterRegistry(adapters: []))
        try editing.setEnabled(accountID: first.id, enabled: false)
        try editing.setEnabled(accountID: first.id, enabled: true)
        try editing.setEnabled(accountID: first.id, enabled: false)
        try FileSyncService.exchange(repository: a, directory: shared, writeBack: true)
        try check(try a.account(id: first.id)?.isEnabled == false, "rapid local edits must survive round trip")
        try FileSyncService.exchange(repository: b, directory: shared, writeBack: true)
        try b.deleteAccount(id: first.id)
        try FileSyncService.exchange(repository: b, directory: shared, writeBack: true)
        try FileSyncService.exchange(repository: a, directory: shared, writeBack: true)
        try check(try a.account(id: first.id) == nil, "stale export must not resurrect deleted account")
        try check(try a.snapshot(accountID: first.id) == nil, "deleted account snapshot must also be removed")
        let path = shared.appendingPathComponent(FileSyncService.fileName)
        let data = try Data(contentsOf: path)
        try check(try decoded(data).accounts.map(\.id) == [second.id], "shared file must retain unrelated account")
        let text = String(decoding: data, as: UTF8.self)
        try check(!text.contains("pipioUserID") && !text.contains("\"secret\""), "shared payload must not include credentials")
        // Import is read-only for shared file, and uses exactly the same merge rules.
        try FileSyncService.exchange(repository: a, directory: shared, writeBack: false)
        try check(try Data(contentsOf: path) == data, "read-only import must not overwrite shared file")
        let unknown = RelaySyncData(schemaVersion: 999, accounts: [], snapshots: [], dailyUsage: [], settings: RelaySettings())
        let unknownSettings = RelaySyncData(accounts: [], snapshots: [], dailyUsage: [], settings: RelaySettings(schemaVersion: 999))
        for badData in [Data("broken json".utf8), try encoded(unknown), try encoded(unknownSettings)] {
            try badData.write(to: path)
            let before = try a.fetchAccounts()
            try rejects("corrupt or unsupported sync file") { try FileSyncService.exchange(repository: a, directory: shared, writeBack: true) }
            try check(try Data(contentsOf: path) == badData, "failed sync must not overwrite original file")
            try check(try a.fetchAccounts() == before, "invalid sync must not mutate local records")
        }
        try rejects("unavailable sync directory") { try FileSyncService.exchange(repository: a, directory: shared.appendingPathComponent("missing"), writeBack: true) }
        try a.upsertAccount(account("still works locally"))
        try check(try a.fetchAccounts().count == 2, "sync failures must leave local repository usable")
    }

    @MainActor static func presentation() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let beforeMidnight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 23, minute: 59, second: 59))!
        let afterMidnight = beforeMidnight.addingTimeInterval(2)
        let repo = RejectingRepository()
        let a = account("cached", at: beforeMidnight)
        var b = account("no snapshot", at: beforeMidnight)
        try repo.upsertAccount(a)
        try repo.upsertAccount(b)
        let snap = snapshot(a.id, at: beforeMidnight)
        try repo.upsertSnapshot(snap)
        let store = RelayStore(repository: repo, credentialStore: InMemoryCredentialStore(), adapters: ProviderAdapterRegistry(adapters: []), calendar: calendar, automaticallyRefresh: false)
        store.updateTemporalPresentation(at: beforeMidnight)
        try check(!store.balanceTotalCNY.isComplete && !store.todaySpendTotalCNY.isComplete, "missing enabled account snapshot must make totals incomplete")
        try check(store.todaySpendTotalCNY.excludedAccountIDs == [b.id], "missing account must be identified")
        b.isEnabled = false
        try repo.upsertAccount(b)
        store.updateTemporalPresentation(at: beforeMidnight)
        try check(store.todaySpendTotalCNY.isComplete && store.todaySpendTotalCNY.value?.amount == 42, "disabled account must not prevent complete total")
        store.updateTemporalPresentation(at: afterMidnight)
        try check(!store.todaySpendTotalCNY.isComplete && store.todaySpendTotalCNY.value == nil, "yesterday cannot be presented as today's spend")
        try check(store.accountModel(id: a.id)?.todaySpend == nil, "account row/detail must invalidate without network")
        try check(store.balanceTotalCNY.value?.amount == 100, "midnight must preserve last known balance")
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        try check(snap.todaySpend(on: afterMidnight, calendar: utc) != nil, "day boundary must honor supplied timezone")
        try check(DashboardAggregator.todaySpendTotal(snapshots: [], targetCurrency: .cny, expectedAccountIDs: []).value == nil, "empty scope must not fabricate zero")
        let zero = snapshot(a.id, at: beforeMidnight, spend: 0)
        try check(DashboardAggregator.todaySpendTotal(snapshots: [zero], targetCurrency: .cny, now: beforeMidnight, calendar: calendar).value?.amount == 0, "reliable zero is not unknown")
        store.setHidden(accountID: a.id, hidden: true)
        try check(try repo.account(id: a.id)?.isHidden == true, "hiding an account must persist its setting")
        try check(!store.dashboardAccounts.contains(where: { $0.id == a.id.uuidString }), "hidden accounts must be excluded from the home projection")
        try check(store.balanceTotalCNY.value == nil, "hidden balance must be excluded from totals")
        try check(store.accountModel(id: a.id)?.isHidden == true, "account model must expose hidden state")
        store.setHidden(accountID: a.id, hidden: false)
        try check(try repo.account(id: a.id)?.isHidden == false && !store.dashboardAccounts.isEmpty, "unhiding an account must restore the home projection")
        repo.rejectWrites = true
        var settings = store.settings
        settings.refreshIntervalSeconds = 900
        store.updateSettings(settings)
        try check(store.settings.refreshIntervalSeconds == 300 && store.globalErrorMessage != nil, "failed settings write must not report published success")
    }
}
