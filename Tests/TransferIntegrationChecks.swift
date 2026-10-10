import Foundation

@MainActor
enum TransferIntegrationChecks {
    private struct Failure: Error { let message: String }
    private static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message: message) }
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-transfer-integration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let backups = LocalBackupService(directoryURL: root)
        let repository = InMemoryLocalRepository()
        let credentialStore = FileCredentialStore(fileURL: root.appendingPathComponent("credentials.json"))
        let account = AccountConfiguration(displayName: "local", providerKind: .pipio,
            siteOrigin: URL(string: "https://example.invalid")!, credentialReference: "private-local-map")
        try repository.upsertAccount(account)
        try await credentialStore.save(ProviderCredential(secret: "fixture-only"), reference: account.credentialReference)
        let record = DailyUsageRecord(accountID: account.id, day: Calendar.current.startOfDay(for: Date()), spend: MoneyValue(amount: 3, currency: .cny), updatedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)))
        try repository.commitDailyUsage([record])
        let store = RelayStore(repository: repository, credentialStore: credentialStore,
            adapters: ProviderAdapterRegistry(adapters: []), automaticallyRefresh: false, backupService: backups)
        var imported = account
        imported.displayName = "imported"
        imported.groupName = "work"
        imported.monthlyBudget = MoneyValue(amount: 100, currency: .cny)
        let archive = RelaySyncData(accounts: [imported], snapshots: [], dailyUsage: [], settings: RelaySettings(refreshIntervalSeconds: 600))
        let preview = try DataTransferService.previewConfiguration(DataTransferService.exportConfiguration(archive), existingAccountIDs: [account.id])
        let before = try store.transferSnapshot()
        try await store.importConfiguration(preview, expectedLocal: before)
        try check(store.accountConfiguration(id: account.id)?.displayName == "imported", "import publishes metadata")
        try check(store.settings.refreshIntervalSeconds == 600, "import publishes settings")
        try check(try repository.account(id: account.id)?.credentialReference == account.credentialReference, "import preserves credential")
        try check(try repository.dailyUsage(accountID: account.id, limit: nil) == [record], "config import preserves history")
        let entries = try await backups.list()
        try check(entries.count == 1, "recovery point saved before import")
        do {
            try await store.importConfiguration(preview, expectedLocal: before)
            throw Failure(message: "stale preview accepted")
        } catch DataTransferError.stalePreview {}
        let safe = RelaySyncDataSafety.sanitized(try repository.syncData())
        try repository.mergeSyncData(safe)
        try check(try repository.account(id: account.id)?.credentialReference == account.credentialReference, "sync preserves local mapping")
        var destination = imported
        destination.siteOrigin = URL(string: "https://changed.invalid")!
        let moved = try DataTransferService.previewConfiguration(DataTransferService.exportConfiguration(
            RelaySyncData(accounts: [destination], snapshots: [], dailyUsage: [], settings: RelaySettings())), existingAccountIDs: [account.id])
        try await store.importConfiguration(moved, expectedLocal: store.transferSnapshot())
        try check(try repository.account(id: account.id)?.credentialReference != account.credentialReference, "new origin cannot inherit old credential")
        try check(try repository.dailyUsage(accountID: account.id, limit: nil).isEmpty, "new origin discards unrelated history")
        let oldBackup = try await backups.preview(entries[0])
        try await store.restoreBackup(oldBackup, expectedLocal: store.transferSnapshot())
        try check(store.accountConfiguration(id: account.id)?.displayName == "local", "restore publishes prior metadata")
        try check(try repository.dailyUsage(accountID: account.id, limit: nil) == [record], "restore restores history")
        let storedCredential = try await credentialStore.read(reference: account.credentialReference)
        try check(storedCredential.secret == "fixture-only", "transfer never changes credential file")
        print("PASSED: store import/restore recovery points, settings/history, stale preview rejection, credential isolation and sync preservation")
    }
}
