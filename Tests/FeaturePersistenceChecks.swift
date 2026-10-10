import Foundation

@MainActor
enum FeaturePersistenceChecks {
    private struct Failure: Error { let message: String }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func run() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let account = AccountConfiguration(displayName: "fixture", providerKind: .pipio,
            siteOrigin: URL(string: "https://example.invalid")!, credentialReference: "local-reference",
            monthlyBudget: MoneyValue(amount: 100, currency: .usd), groupName: "work", isPinned: true)
        var old = try JSONSerialization.jsonObject(with: encoder.encode(account)) as! [String: Any]
        old.removeValue(forKey: "monthlyBudget")
        old.removeValue(forKey: "groupName")
        old.removeValue(forKey: "isPinned")
        let legacy = try decoder.decode(AccountConfiguration.self, from: JSONSerialization.data(withJSONObject: old))
        try require(legacy.monthlyBudget == nil && legacy.groupName == nil && !legacy.isPinned, "old JSON defaults")
        let sanitized = RelaySyncDataSafety.sanitized(RelaySyncData(accounts: [account], snapshots: [], dailyUsage: [], settings: RelaySettings()))
        try require(sanitized.accounts[0].credentialReference == account.id.uuidString, "credential reference sanitized")
        try require(sanitized.accounts[0].monthlyBudget == account.monthlyBudget && sanitized.accounts[0].groupName == "work" && sanitized.accounts[0].isPinned, "preferences survive sync projection")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-feature-persistence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try FileLocalRepository(fileURL: directory.appendingPathComponent("local.json"))
        try repository.upsertAccount(account)
        let today = Calendar.current.startOfDay(for: Date())
        let first = DailyUsageRecord(accountID: account.id, day: today, spend: MoneyValue(amount: 2, currency: .usd))
        let second = DailyUsageRecord(accountID: account.id, day: today.addingTimeInterval(-86400), spend: nil)
        try repository.commitDailyUsage([first, second])
        try require(try repository.dailyUsage(accountID: account.id, limit: nil).count == 2, "batch saved")
        try repository.mergeSyncData(sanitized)
        try require(try repository.account(id: account.id)?.credentialReference == account.credentialReference, "file sync preserves local mapping")
        let before = try repository.syncData()
        var changed = account
        changed.displayName = "changed"
        try repository.upsertAccount(changed)
        let empty = RelaySyncData(accounts: [], snapshots: [], dailyUsage: [], settings: RelaySettings())
        try require(try !repository.replaceNonsecretData(empty, expected: before), "stale preview rejected")
        let current = try repository.syncData()
        try require(try repository.replaceNonsecretData(before, expected: current), "explicit restore")
        let reopened = try FileLocalRepository(fileURL: directory.appendingPathComponent("local.json"))
        try require(try reopened.account(id: account.id)?.monthlyBudget == account.monthlyBudget, "metadata restored on disk")
        try require(try reopened.dailyUsage(accountID: account.id, limit: nil).count == 2, "history restored")
        print("Feature persistence checks passed")
    }
}
