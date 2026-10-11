import Foundation
import Darwin

private enum StrengtheningFault: Error { case failed }
private actor StrengtheningCredentials: CredentialStore {
    var values: [String: ProviderCredential] = [:]
    var failDelete = false
    func read(reference: String) async throws -> ProviderCredential {
        guard let value = values[reference] else { throw CredentialStoreError.notFound }; return value
    }
    func save(_ credential: ProviderCredential, reference: String) async throws { values[reference] = credential }
    func delete(reference: String) async throws {
        if failDelete { throw StrengtheningFault.failed }; values.removeValue(forKey: reference)
    }
    func count() -> Int { values.count }
    func setFailure() { failDelete = true }
}
private struct StrengtheningAdapter: ProviderAdapter {
    let kind: ProviderKind = .pipio
    func validateAccount(_ account: AccountConfiguration, credential: ProviderCredential) async throws {}
    func fetchAccountRate(for account: AccountConfiguration, credential: ProviderCredential) async throws -> AccountRate {
        AccountRate(accountID: account.id, source: .providerNativeCurrency, nativeCurrency: .cny)
    }
    func fetchSnapshot(for account: AccountConfiguration, credential: ProviderCredential, rate: AccountRate, now: Date, calendar: Calendar) async throws -> ProviderSnapshot {
        ProviderSnapshot(accountID: account.id, balance: MoneyValue(amount: 100, currency: .cny),
            todaySpend: MoneyValue(amount: 2, currency: .cny), monthSpend: nil, requestCount: nil,
            capabilities: [.balance, .todayUsage], freshness: .fresh, fetchedAt: now, rate: rate)
    }
}

@MainActor
enum StrengtheningChecks {
    private static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw NSError(domain: message, code: 1) }
    }
    private static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }; throw StrengtheningFault.failed
    }
    private static func rejectsAsync(_ body: () async throws -> Void) async throws {
        do { try await body() } catch { return }; throw StrengtheningFault.failed
    }
    static func run() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/relay-strengthening-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await recovery(root)
        try await creation(root)
        try await migration(root)
        try await interruptedMigration(root)
        try organizationAndAnalytics()
        try redirectsAndDiagnostics()
        try await notifications()
        print("PASSED: corrupt-store backup rescue, stale/version protection, account atomic commit/compensation, restart migration cleanup, batch organization, monthly coverage, import differences, redirect policy and diagnostic whitelist")
    }
    private static func recovery(_ root: URL) async throws {
        let url = root.appendingPathComponent("damaged.json")
        let original = Data("{damaged fixture".utf8)
        try original.write(to: url)
        let repository = RecoverableLocalRepository(recoveryFileURL: url) { try FileLocalRepository(fileURL: url) }
        let backups = LocalBackupService(directoryURL: root.appendingPathComponent("recovery-backups"))
        let account = AccountConfiguration(displayName: "Recovered", providerKind: .pipio,
            siteOrigin: URL(string: "https://example.invalid")!, credentialReference: "private-original-reference")
        let data = RelaySyncData(accounts: [account], snapshots: [], dailyUsage: [], settings: RelaySettings())
        let entry = try await backups.create(data)
        let credentials = StrengtheningCredentials()
        let store = RelayStore(repository: repository, credentialStore: credentials, adapters: .init(adapters: []), automaticallyRefresh: false, backupService: backups)
        let preview = try await store.previewStorageRecovery(entry)
        try Data("{changed fixture".utf8).write(to: url)
        try await rejectsAsync { try await store.restoreDamagedStorage(preview) }
        try check(!store.storageAvailability.isAvailable, "Stale rescue does not release storage failure")
        try original.write(to: url)
        let alteredBackup = RelaySyncData(accounts: [], snapshots: [], dailyUsage: [], settings: RelaySettings())
        let originalBackup = try Data(contentsOf: entry.fileURL)
        try DataTransferService.exportBackup(alteredBackup).write(to: entry.fileURL)
        try await rejectsAsync { try await store.restoreDamagedStorage(preview) }
        try originalBackup.write(to: entry.fileURL)
        try await store.restoreDamagedStorage(preview)
        try check(store.storageAvailability.isAvailable && store.accountConfigurations.count == 1, "Rescue works without reading the corrupt store")
        try check(store.accountConfigurations[0].credentialReference != account.credentialReference, "Rescue cannot reuse an unverified origin credential mapping")
        try check(!store.settings.iCloudFileSyncEnabled, "Rescue keeps sync disabled")
        let preserved = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("relay-damaged-") }
        try check(preserved.count == 1 && (try Data(contentsOf: preserved[0])) == original, "Corrupt original preserved byte for byte")
        let count = await credentials.count()
        try check(count == 0, "Rescue never accesses or changes credential bodies")
        try Data("{\"schemaVersion\":99}".utf8).write(to: url)
        try rejects { _ = try FileLocalRepository.recoveryOriginal(at: url) }
        store.cancelRefreshes()
    }
    private static func creation(_ root: URL) async throws {
        let url = root.appendingPathComponent("creation.json")
        let repository = try FileLocalRepository(fileURL: url)
        let credentials = StrengtheningCredentials()
        let service = AccountService(repository: repository, credentialStore: credentials, adapters: .init(adapters: [StrengtheningAdapter()]))
        let draft = AccountDraft(displayName: "Created", providerKind: .pipio, baseURL: "https://example.invalid", credential: .init(secret: "fixture-token", pipioUserID: "1"))
        let account = try await service.addAccount(draft)
        let restarted = try FileLocalRepository(fileURL: url)
        try check(try restarted.account(id: account.id) != nil && restarted.snapshot(accountID: account.id) != nil && restarted.dailyUsage(accountID: account.id, limit: nil).count == 1, "All first-snapshot data survives restart")
        let before = try repository.syncData()
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try await rejectsAsync { _ = try await service.addAccount(draft) }
        try check(try repository.syncData().hasSameContent(as: before), "Failed account commit leaves complete state unchanged")
        let count = await credentials.count()
        try check(count == 1, "Only failed new credential is compensated")
        await credentials.setFailure()
        do { _ = try await service.addAccount(draft); throw StrengtheningFault.failed }
        catch AccountServiceError.credentialRollbackFailed {}
        try check(try repository.syncData().hasSameContent(as: before), "Compensation failure remains visible without a half-account")
    }
    private static func migration(_ root: URL) async throws {
        let source = root.appendingPathComponent("migration-source")
        let target = root.appendingPathComponent("migration-target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let suite = "relay-strengthening-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let codec = BackupDirectoryBookmarkCodec(encode: { Data($0.path.utf8) }, decode: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self), isDirectory: true) })
        let failed = LocalBackupService(directoryURL: source, preferences: defaults, codec: codec, credentialDirectoryURL: root.appendingPathComponent("credentials"), migrationIO: .init(remove: { _ in throw StrengtheningFault.failed }))
        let entry = try await failed.create(RelaySyncData(accounts: [], snapshots: [], dailyUsage: [], settings: RelaySettings()))
        let warning = try await failed.selectDirectory(target)
        try check(warning != nil, "Cleanup failures stay visible")
        let pending = await failed.hasPendingMigration()
        try check(pending, "Migration manifest survives cleanup failure")
        let restarted = LocalBackupService(directoryURL: source, preferences: defaults, codec: codec, credentialDirectoryURL: root.appendingPathComponent("credentials"))
        let duplicate = target.appendingPathComponent("RelayBackups").appendingPathComponent(entry.fileURL.lastPathComponent)
        let bytes = try Data(contentsOf: duplicate)
        try Data("external-change".utf8).write(to: duplicate)
        let blocked = try await restarted.retryPendingMigration()
        try check(blocked != nil && FileManager.default.fileExists(atPath: entry.fileURL.path), "Modified destination never authorizes deleting original")
        try bytes.write(to: duplicate)
        let resolved = try await restarted.retryPendingMigration()
        try check(resolved == nil && !FileManager.default.fileExists(atPath: entry.fileURL.path) && FileManager.default.fileExists(atPath: duplicate.path), "Restart retry cleans only a verified original")
        let summary = try await restarted.summary()
        try check(summary.count == 1 && summary.totalBytes == bytes.count && !summary.pendingMigration, "Backup summary counts verified backups only")
    }
    static func crashFixture(root: URL, stage: String) async throws {
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        let codec = BackupDirectoryBookmarkCodec(encode: { Data($0.path.utf8) }, decode: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self), isDirectory: true) })
        let suite = "relay-crash-" + root.lastPathComponent
        let defaults = UserDefaults(suiteName: suite)!
        var io = BackupMigrationIO()
        if stage == "copy" {
            io.write = { bytes, url in try PrivateFileWriter.write(bytes, to: url); _exit(71) }
        } else { io.remove = { _ in _exit(72) } }
        let service = LocalBackupService(directoryURL: source, preferences: defaults, codec: codec,
            credentialDirectoryURL: root.appendingPathComponent("credentials"), migrationIO: io)
        _ = try await service.selectDirectory(target)
        throw StrengtheningFault.failed
    }

    private static func interruptedMigration(_ root: URL) async throws {
        for stage in ["copy", "cleanup"] {
            let fixtureRoot = root.appendingPathComponent("crash-" + stage)
            let source = fixtureRoot.appendingPathComponent("source"), target = fixtureRoot.appendingPathComponent("target")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let suite = "relay-crash-" + fixtureRoot.lastPathComponent
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defer { defaults.removePersistentDomain(forName: suite) }
            let codec = BackupDirectoryBookmarkCodec(encode: { Data($0.path.utf8) }, decode: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self), isDirectory: true) })
            let service = LocalBackupService(directoryURL: source, preferences: defaults, codec: codec,
                credentialDirectoryURL: fixtureRoot.appendingPathComponent("credentials"))
            let data = RelaySyncData(accounts: [], snapshots: [], dailyUsage: [], settings: RelaySettings())
            let first = try await service.create(data)
            let second = try await service.create(data)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--backup-crash-fixture", fixtureRoot.path, stage]
            try process.run(); process.waitUntilExit()
            try check(process.terminationStatus == (stage == "copy" ? 71 : 72), "Child terminates without unwinding migration")
            // Intentionally discard all preference hints: the atomic selection
            // file alone must decide whether copies are committed or rolled back.
            defaults.removePersistentDomain(forName: suite)
            let reopened = LocalBackupService(directoryURL: source, preferences: defaults, codec: codec,
                credentialDirectoryURL: fixtureRoot.appendingPathComponent("credentials"))
            let warning = try await reopened.retryPendingMigration()
            try check(warning == nil, "Interrupted migration safely converges after restart")
            let pending = await reopened.hasPendingMigration()
            try check(!pending, "Successful convergence clears migration manifest")
            let originalsExist = FileManager.default.fileExists(atPath: first.fileURL.path) && FileManager.default.fileExists(atPath: second.fileURL.path)
            let entries = try await reopened.list()
            try check(entries.count == 2 && originalsExist == (stage == "copy"), "Commit stage determines verified rollback versus old-copy cleanup")
        }
    }

    private static func organizationAndAnalytics() throws {
        let repository = InMemoryLocalRepository()
        var a = AccountConfiguration(displayName: "A", providerKind: .pipio, siteOrigin: URL(string: "https://example.invalid")!)
        let b = AccountConfiguration(displayName: "B", providerKind: .pipio, siteOrigin: URL(string: "https://other.invalid")!)
        try repository.upsertAccount(a); try repository.upsertAccount(b)
        let store = RelayStore(repository: repository, credentialStore: StrengtheningCredentials(), adapters: .init(adapters: []), automaticallyRefresh: false,
            backupService: LocalBackupService(directoryURL: URL(fileURLWithPath: "/private/tmp/relay-unused-backups")))
        let before = try repository.syncData()
        try rejects { try store.organizeAccounts([a.id, UUID()], group: "X", changeGroup: true) }
        try check(try repository.syncData().hasSameContent(as: before), "Stale selection rejects entire batch")
        try store.organizeAccounts([a.id, b.id], group: " Work ", changeGroup: true, hidden: true, enabled: false)
        try check(try repository.fetchAccounts().allSatisfy { $0.groupName == "Work" && $0.isHidden && !$0.isEnabled }, "Group/visibility/enable flags applied together")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12))!
        func day(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: day))! }
        let records = [DailyUsageRecord(accountID: a.id, day: day(10, 1), spend: .init(amount: 5, currency: .cny)),
            DailyUsageRecord(accountID: a.id, day: day(10, 2), spend: .init(amount: 5, currency: .cny)),
            DailyUsageRecord(accountID: a.id, day: day(9, 1), spend: .init(amount: 2, currency: .cny)),
            DailyUsageRecord(accountID: a.id, day: day(9, 2), spend: .init(amount: 3, currency: .cny))]
        let rows = ConsumptionOverviewService.rows(accounts: [a], history: records, at: now, calendar: calendar)
        try check(rows[0].month.amounts[0].amount == 10 && rows[0].changePercent == 100, "Same-period complete comparison is correct")
        let incomplete = ConsumptionOverviewService.rows(accounts: [a], history: Array(records.dropFirst()), at: now, calendar: calendar)
        try check(incomplete[0].changePercent == nil && incomplete[0].month.knownDays == 1 && incomplete[0].month.expectedDays == 3, "Missing day is unknown, not zero or a certain increase")
        var mixed = records
        mixed[1] = DailyUsageRecord(accountID: a.id, day: day(10, 2), spend: .init(amount: 5, currency: .usd))
        let mixedRows = ConsumptionOverviewService.rows(accounts: [a], history: mixed, at: now, calendar: calendar)
        try check(mixedRows[0].month.amounts.count == 2 && mixedRows[0].changePercent == nil, "Mixed currencies remain separate")
        a.siteOrigin = URL(string: "https://changed.invalid")!; a.groupName = "New"
        let preview = ConfigurationImportPreview(archive: RelayConfigurationArchive(accounts: [a], settings: RelaySettings()), existingAccountIDs: [a.id, b.id])
        let diffs = ConfigurationDiffService.accounts(preview, current: before)
        try check(diffs[0].clearsHistory && diffs[0].needsCredential && diffs[0].changes.contains { $0.title == "站点" }, "Destination changes warn about history and credentials")
        store.cancelRefreshes()
    }
    private static func notifications() async throws {
        var submissions = 0
        let denied = NotificationStatusService(actions: .init(readStatus: { "denied" }, requestPermission: { false }, submitSample: { submissions += 1 }))
        await denied.test()
        try check(submissions == 0 && denied.authorizationText == "denied" && denied.deliveryMessage?.contains("未允许") == true && !denied.isTesting, "Denied authorization does not submit or stick busy")
        let allowed = NotificationStatusService(actions: .init(readStatus: { "allowed" }, requestPermission: { true }, submitSample: { submissions += 1 }))
        await allowed.test()
        try check(submissions == 1 && allowed.deliveryMessage?.contains("是否展示") == true, "Accepted test never claims actual banner delivery")
        let failure = NotificationStatusService(actions: .init(readStatus: { "allowed" }, requestPermission: { true }, submitSample: { throw StrengtheningFault.failed }))
        await failure.test()
        try check(failure.deliveryMessage?.contains("失败") == true && !failure.isTesting, "Failed test is visible and releases the button")
    }

    private static func redirectsAndDiagnostics() throws {
        var original = URLRequest(url: URL(string: "https://EXAMPLE.invalid/api")!)
        original.setValue("fixture-token", forHTTPHeaderField: "Authorization")
        original.setValue("fixture-id", forHTTPHeaderField: "Pipio-User")
        let same = ProviderRedirectPolicy.redirectedRequest(original: original, proposed: URLRequest(url: URL(string: "https://example.invalid:443/next")!))
        try check(same?.value(forHTTPHeaderField: "Authorization") == "fixture-token", "Same-origin normalized port retains authentication")
        for destination in ["https://other.invalid/api", "http://example.invalid/api", "https://example.invalid:444/api", "https://user@example.invalid/api"] {
            try check(ProviderRedirectPolicy.redirectedRequest(original: original, proposed: URLRequest(url: URL(string: destination)!)) == nil, "Cross-origin/user-info/downgrade redirect rejected")
        }
        let repository = InMemoryLocalRepository()
        let account = AccountConfiguration(displayName: "PRIVATE_ACCOUNT_MARKER", providerKind: .pipio,
            siteOrigin: URL(string: "https://private-marker.invalid")!, credentialReference: "PRIVATE_REFERENCE_MARKER")
        try repository.upsertAccount(account)
        let store = RelayStore(repository: repository, credentialStore: StrengtheningCredentials(), adapters: .init(adapters: []), automaticallyRefresh: false)
        let text = String(decoding: try store.diagnosticReport().encoded(), as: UTF8.self)
        for marker in ["PRIVATE_ACCOUNT_MARKER", "private-marker.invalid", "PRIVATE_REFERENCE_MARKER", account.id.uuidString, "Authorization", "credentialReference"] {
            try check(!text.contains(marker), "Diagnostics whitelist excludes identifiers and secret fields")
        }
        try check(text.contains("accountCount") && text.contains("systemVersion"), "Diagnostics retain useful aggregate information")
        store.cancelRefreshes()
    }
}
