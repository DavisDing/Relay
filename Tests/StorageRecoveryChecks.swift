import Foundation

private struct StorageRecoveryFailure: Error, CustomStringConvertible {
    let description: String
}

private actor RecoveryCredentials: CredentialStore {
    var writes = 0
    func read(reference: String) async throws -> ProviderCredential { throw CredentialStoreError.notFound }
    func save(_ credential: ProviderCredential, reference: String) async throws { writes += 1 }
    func delete(reference: String) async throws { writes += 1 }
}

@MainActor
enum StorageRecoveryChecks {
    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw StorageRecoveryFailure(description: message) }
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("local.json")
        let original = Data("{".utf8)
        try original.write(to: url)
        let credentials = RecoveryCredentials()
        let repository = RecoverableLocalRepository { try FileLocalRepository(fileURL: url) }
        let store = RelayStore(repository: repository, credentialStore: credentials,
                               adapters: ProviderAdapterRegistry(adapters: []), automaticallyRefresh: false)
        try check(store.storageAvailability == .unavailable(.corruptData), "Corrupt startup is an explicit persistent state")
        let message = store.globalErrorMessage
        await store.refreshAll()
        await store.refresh(accountID: UUID())
        store.updateTemporalPresentation(at: Date())
        store.updateSettings(RelaySettings())
        try check(store.globalErrorMessage == message && !store.storageAvailability.isAvailable, "Refresh/settings/clock cannot erase a startup storage failure")
        let draft = AccountDraft(displayName: "fixture", providerKind: .pipio, baseURL: "https://example.invalid",
                                 credential: ProviderCredential(secret: "fixture-only", pipioUserID: "1"))
        do {
            try await store.addAccount(draft)
            throw StorageRecoveryFailure(description: "Adding to unavailable storage succeeded")
        } catch LocalRepositoryError.corruptData {}
        let writes = await credentials.writes
        try check(writes == 0, "Storage guards run before credential writes or provider requests")
        store.retryOpeningStorage()
        try check(!store.storageAvailability.isAvailable && (try Data(contentsOf: url)) == original, "Failed retry preserves original bytes and failure state")

        try Data("{\"schemaVersion\":3}".utf8).write(to: url)
        let unsupportedBytes = try Data(contentsOf: url)
        store.retryOpeningStorage()
        try check(store.storageAvailability == .unavailable(.unsupportedVersion), "Unknown versions are not corruption")
        try check(try Data(contentsOf: url) == unsupportedBytes, "Future schema is never rewritten")

        // A directory at the expected file path must be an unreadable file,
        // including when fileExists alone would misleadingly suggest a valid path.
        let directoryURL = root.appendingPathComponent("directory.json")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        let unreadable = RecoverableLocalRepository { try FileLocalRepository(fileURL: directoryURL) }
        try check(unreadable.availability == .unavailable(.unreadable), "Read failures remain distinct from invalid JSON")

        // Restore valid non-secret data externally, then reopen through the same services.
        let account = AccountConfiguration(displayName: "Recovered", providerKind: .pipio,
                                           siteOrigin: URL(string: "https://example.invalid")!)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(RelaySyncData(accounts: [account], snapshots: [], dailyUsage: [], settings: RelaySettings())).write(to: url)
        store.retryOpeningStorage()
        try check(store.storageAvailability.isAvailable && store.accounts.first?.name == "Recovered", "Successful complete load restores the projection")
        try check(store.repositoryErrorMessage == nil && store.globalErrorMessage == nil, "Successful retry clears only the storage error")
        store.setHidden(accountID: account.id, hidden: true)
        let restarted = try FileLocalRepository(fileURL: url)
        try check(try restarted.account(id: account.id)?.isHidden == true, "Services retain the recovered repository identity and persist edits")
        store.cancelRefreshes()
        print("PASSED: persistent startup failures, read/corruption/version distinction, guarded credential writes, original file preservation and reopen recovery")
    }
}
