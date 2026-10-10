import Foundation

private struct DataTransferCheckFailure: Error, CustomStringConvertible { let description: String }

@MainActor
enum DataTransferChecks {
    private static func check(_ value: @autoclosure () throws -> Bool, _ text: String) throws {
        if try !value() { throw DataTransferCheckFailure(description: text) }
    }
    private static func rejects(_ action: () throws -> Void, _ message: String) throws {
        do { try action(); throw DataTransferCheckFailure(description: message) }
        catch is DataTransferCheckFailure { throw DataTransferCheckFailure(description: message) }
        catch {}
    }

    static func run() async throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_770_000_000)
        let account = AccountConfiguration(displayName: "=SUM(1,2)\"\nname", providerKind: .pipio,
                                           siteOrigin: URL(string: "https://example.invalid")!,
                                           credentialReference: "must-never-transfer")
        let other = AccountConfiguration(displayName: "Other", providerKind: .deepseek,
                                         siteOrigin: URL(string: "https://api.deepseek.com")!)
        let records = [DailyUsageRecord(accountID: account.id, day: day, spend: MoneyValue(amount: 0, currency: .cny), updatedAt: day),
                       DailyUsageRecord(accountID: account.id, day: calendar.date(byAdding: .day, value: 1, to: day)!, spend: nil, updatedAt: day),
                       DailyUsageRecord(accountID: other.id, day: day, spend: MoneyValue(amount: 2.5, currency: .usd), updatedAt: day)]
        let data = RelaySyncData(accounts: [account, other], snapshots: [], dailyUsage: records, settings: RelaySettings())
        let config = try DataTransferService.exportConfiguration(data)
        let configText = String(decoding: config, as: UTF8.self)
        try check(!configText.contains("must-never-transfer") && !configText.contains("dailyUsage"), "Config excludes secret refs and usage")
        let preview = try DataTransferService.previewConfiguration(config, existingAccountIDs: [account.id])
        try check(preview.addedAccountCount == 1 && preview.updatedAccountCount == 1, "Config preview distinguishes additions and updates")
        try check(preview.archive.accounts.first?.credentialReference == account.id.uuidString, "Decoded reference is account identity only")
        var object = try JSONSerialization.jsonObject(with: config) as! [String: Any]
        object["token"] = "unacceptable"
        try rejects({ _ = try DataTransferService.previewConfiguration(JSONSerialization.data(withJSONObject: object), existingAccountIDs: []) }, "Sensitive root fields rejected")
        object.removeValue(forKey: "token"); object["schemaVersion"] = 999
        try rejects({ _ = try DataTransferService.previewConfiguration(JSONSerialization.data(withJSONObject: object), existingAccountIDs: []) }, "Future config rejected")
        let duplicated = RelaySyncData(accounts: [account, account], snapshots: [], dailyUsage: [], settings: RelaySettings())
        try rejects({ _ = try DataTransferService.exportConfiguration(duplicated) }, "Repeated account IDs rejected")
        let queryAccount = AccountConfiguration(displayName: "Invalid", providerKind: .pipio,
                                               siteOrigin: URL(string: "https://example.invalid?token=x")!)
        try rejects({ _ = try DataTransferService.exportConfiguration(RelaySyncData(accounts: [queryAccount], snapshots: [], dailyUsage: [], settings: RelaySettings())) }, "Secret-bearing URL query rejected")
        let insecure = AccountConfiguration(displayName: "Invalid", providerKind: .pipio,
            siteOrigin: URL(string: "http://example.invalid")!)
        try rejects({ _ = try DataTransferService.exportConfiguration(RelaySyncData(accounts: [insecure], snapshots: [], dailyUsage: [], settings: RelaySettings())) }, "Plain HTTP provider import rejected")
        let huge = Data(repeating: 0, count: DataTransferService.maximumFileBytes + 1)
        try rejects({ _ = try DataTransferService.previewConfiguration(huge, existingAccountIDs: []) }, "Size limit rejected before decode")
        let csv = String(decoding: try DataTransferService.exportUsageCSV(data, accountIDs: [account.id], from: day,
                          through: calendar.date(byAdding: .day, value: 1, to: day)!, calendar: calendar), as: UTF8.self)
        try check(csv.contains("\"'=SUM(1,2)\"\"\nname\"") && csv.contains("\"0\",\"CNY\",\"recorded\""), "CSV formula/quotes safely escaped and true zero retained")
        try check(csv.contains("\"\",\"\",\"unknown\"") && !csv.contains(other.id.uuidString), "Unknown blank and account filter preserved")
        try rejects({ _ = try DataTransferService.exportUsageCSV(data, from: day.addingTimeInterval(86_400), through: day, calendar: calendar) }, "Reversed range rejected")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-backup-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let backups = LocalBackupService(directoryURL: root)
        for index in 0..<7 { _ = try await backups.create(data, at: day.addingTimeInterval(Double(index))) }
        let entries = try await backups.list()
        try check(entries.count == 5 && entries.first?.createdAt == day.addingTimeInterval(6), "Five newest generations retained")
        let restored = try await backups.preview(entries[0])
        try check(restored.data.dailyUsage == records && restored.data.accounts.first?.credentialReference == account.id.uuidString,
                  "Backup preview retains usage and sanitizes credential refs")
        let attributes = try FileManager.default.attributesOfItem(atPath: entries[0].fileURL.path)
        try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Backup files are owner-only")
        let unrelated = root.appendingPathComponent("keep.json"); try Data("fixture".utf8).write(to: unrelated)
        _ = try await backups.create(data, at: day.addingTimeInterval(10))
        try check(FileManager.default.fileExists(atPath: unrelated.path), "Prune never deletes unrelated files")
        let fake = LocalBackupEntry(id: entries[0].id, createdAt: day, fileURL: root.deletingLastPathComponent().appendingPathComponent(entries[0].fileURL.lastPathComponent), accountCount: 0, historyCount: 0)
        do { _ = try await backups.preview(fake); throw DataTransferCheckFailure(description: "Outside path accepted") }
        catch DataTransferError.backupUnavailable {}
        let automatic = LocalBackupService(directoryURL: root.appendingPathComponent("automatic"))
        let firstAutomatic = try await automatic.createIfNeeded(data, at: day, calendar: calendar)
        let repeatedAutomatic = try await automatic.createIfNeeded(data, at: day.addingTimeInterval(60), calendar: calendar)
        let nextDayAutomatic = try await automatic.createIfNeeded(data, at: calendar.date(byAdding: .day, value: 1, to: day)!, calendar: calendar)
        let automaticEntries = try await automatic.list()
        try check(firstAutomatic != nil && repeatedAutomatic == nil && nextDayAutomatic != nil && automaticEntries.count == 2,
                  "Daily automatic backup creates once per calendar day")
        let manualDate = calendar.date(byAdding: .day, value: 2, to: day)!
        _ = try await automatic.create(data, at: manualDate)
        let afterManual = try await automatic.createIfNeeded(data, at: manualDate.addingTimeInterval(60), calendar: calendar)
        try check(afterManual == nil, "A manual backup satisfies today's automatic recovery point")
        let prior = try await backups.list()
        do { _ = try await backups.create(duplicated); throw DataTransferCheckFailure(description: "Invalid generation accepted") }
        catch DataTransferError.invalidAccounts {}
        let after = try await backups.list()
        try check(prior == after, "Invalid backup cannot prune good generations")
        print("PASSED: nonsecret config validation/preview, bounded files, CSV filters and formula safety, unknown versus zero, owner-private backups, five-generation retention and preview path safety")
    }
}
