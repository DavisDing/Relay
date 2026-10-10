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
        try await directorySelectionChecks(data: data, root: root, day: day)
        print("PASSED: nonsecret config validation/preview, bounded files, CSV filters and formula safety, unknown versus zero, owner-private backups, five-generation retention and preview path safety")
    }

    private static func directorySelectionChecks(data: RelaySyncData, root: URL, day: Date) async throws {
        let manager = FileManager.default
        let canonicalRoot = root.resolvingSymlinksInPath()
        let missingAliasRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("relay-absent-alias-\(UUID().uuidString)/nested/backups", isDirectory: true)
        let aliasService = LocalBackupService(directoryURL: missingAliasRoot)
        let normalizedAlias = try await aliasService.currentDirectoryURL()
        defer { try? manager.removeItem(at: normalizedAlias.deletingLastPathComponent().deletingLastPathComponent()) }
        let aliasEntry = try await aliasService.create(data, at: day)
        try check(normalizedAlias.path.hasPrefix("/private/tmp/") && manager.fileExists(atPath: aliasEntry.fileURL.path),
                  "Absent injected fallback resolves system temporary alias through existing ancestor")
        let suite = "relay-backup-directory-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fallback = canonicalRoot.appendingPathComponent("default")
        let firstParent = canonicalRoot.appendingPathComponent("selected-one")
        let secondParent = canonicalRoot.appendingPathComponent("selected-two")
        let credentials = canonicalRoot.appendingPathComponent("credentials")
        for directory in [firstParent, secondParent, credentials] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        let fixtureCodec = BackupDirectoryBookmarkCodec(
            encode: { Data($0.path.utf8) },
            decode: { bytes in
                guard let path = String(data: bytes, encoding: .utf8), path.hasPrefix("/") else { throw BackupDirectoryError.bookmarkUnavailable }
                return URL(fileURLWithPath: path, isDirectory: true)
            })
        let service = LocalBackupService(directoryURL: fallback, preferences: defaults, codec: fixtureCodec, credentialDirectoryURL: credentials)
        _ = try await service.create(data, at: day)
        let initial = try await service.list()
        try await service.selectDirectory(firstParent)
        let chosen = try await service.currentDirectoryURL()
        let empty = try await service.list()
        try check(chosen == firstParent.appendingPathComponent("RelayBackups", isDirectory: true) && empty.count == initial.count,
                  "Selected parent receives old backups in dedicated child")
        try check(!manager.fileExists(atPath: initial[0].fileURL.path), "Default originals removed after verified move")
        let parentAttributes = try manager.attributesOfItem(atPath: firstParent.path)
        try check((parentAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o755, "Selecting never chmods user parent")
        let firstEntry = try await service.create(data, at: day)
        let restarted = LocalBackupService(directoryURL: fallback, preferences: defaults, codec: fixtureCodec, credentialDirectoryURL: credentials)
        let reloaded = try await restarted.currentDirectoryURL()
        try check(reloaded == chosen, "Local bookmark restores chosen folder after restart")
        try await service.selectDirectory(secondParent)
        try check(!manager.fileExists(atPath: firstEntry.fileURL.path), "Switching removes verified old originals")
        let newEntries = try await service.list()
        try check(newEntries.count == 2, "New selected directory lists all moved backups")
        do { _ = try await service.preview(firstEntry); throw DataTransferCheckFailure(description: "Old selected preview accepted after switch") }
        catch DataTransferError.backupUnavailable {}
        try await service.selectDirectory(firstParent)
        let oldEntries = try await service.list()
        try check(oldEntries.count == 2, "Moving back preserves both backups")
        try await service.resetDirectory()
        let reset = try await service.list()
        try check(reset.count == 2 && defaults.object(forKey: LocalBackupService.bookmarkPreferenceKey) == nil,
                  "Reset moves backups to default and clears local preference")
        do { try await service.selectDirectory(credentials); throw DataTransferCheckFailure(description: "Credential directory accepted") }
        catch BackupDirectoryError.credentialDirectory {}
        do { try await service.selectDirectory(canonicalRoot); throw DataTransferCheckFailure(description: "Credential parent accepted") }
        catch BackupDirectoryError.credentialDirectory {}
        let alias = canonicalRoot.appendingPathComponent("credential-link")
        try manager.createSymbolicLink(at: alias, withDestinationURL: credentials)
        do { try await service.selectDirectory(alias); throw DataTransferCheckFailure(description: "Credential symlink accepted") }
        catch BackupDirectoryError.invalidDirectory {}
        let blockedParent = canonicalRoot.appendingPathComponent("blocked")
        try manager.createDirectory(at: blockedParent, withIntermediateDirectories: true)
        try Data("existing file".utf8).write(to: blockedParent.appendingPathComponent("RelayBackups"))
        do { try await service.selectDirectory(blockedParent); throw DataTransferCheckFailure(description: "Invalid child accepted") }
        catch BackupDirectoryError.invalidDirectory {}
        try check(defaults.object(forKey: LocalBackupService.bookmarkPreferenceKey) == nil, "Invalid selection does not persist")
        try await service.selectDirectory(firstParent)
        defaults.set(Data("broken".utf8), forKey: LocalBackupService.bookmarkPreferenceKey)
        do { _ = try await service.list(); throw DataTransferCheckFailure(description: "Broken bookmark fell back silently") }
        catch BackupDirectoryError.bookmarkUnavailable {}
        do { _ = try await service.resetDirectory(); throw DataTransferCheckFailure(description: "Broken source reset silently ignored migration") }
        catch BackupDirectoryError.bookmarkUnavailable {}
        try await service.selectDirectory(firstParent)
        let renewed = try await service.list()
        try check(renewed.count == 2, "Reselecting same parent renews lost authorization without losing backups")
        let staleCodec = BackupDirectoryBookmarkCodec(encode: fixtureCodec.encode, decode: { _ in throw BackupDirectoryError.bookmarkUnavailable })
        let staleService = LocalBackupService(directoryURL: fallback, preferences: defaults, codec: staleCodec, credentialDirectoryURL: credentials)
        do { _ = try await staleService.create(data); throw DataTransferCheckFailure(description: "Stale bookmark wrote default backup") }
        catch BackupDirectoryError.bookmarkUnavailable {}
        try check(manager.fileExists(atPath: oldEntries[0].fileURL.path), "Bad bookmark preserves old backup bytes")
        try await service.resetDirectory()
        print("PASSED: backup directory selection/restart/reset, isolated local preference, dedicated child permissions, verified moved backups, fail-closed bookmark and credential/symlink protection")
    }

}
