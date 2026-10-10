import Foundation

private struct RepositoryPerformanceCheckFailure: Error, CustomStringConvertible {
    let description: String
}

/// Standalone checks callable by the parent regression runner. All files live
/// in temporary directories; no default repository, credentials or network are used.
@MainActor
enum RepositoryPerformanceChecks {
    struct FixtureResult {
        let accountCount: Int
        let historyCount: Int
        let fileBytes: Int
        let reloadMilliseconds: Double
        let commitMilliseconds: Double
        let indexedReadMilliseconds: Double
        let scanSortReadMilliseconds: Double
    }

    private struct Seed: Encodable {
        var schemaVersion = 2
        var accounts: [AccountConfiguration]
        var snapshots: [ProviderSnapshot] = []
        var dailyUsage: [DailyUsageRecord]
        var settings = RelaySettings(historyRetention: .forever)
        var settingsUpdatedAt: Date? = nil
        var deletedAccountIDs: [UUID: Date] = [:]
    }

    static func run() throws {
        try advisoryBoundaries()
        try indexedReadsAndCompatibility()
        try failedCommitsKeepCommittedState()
        let result = try performanceFixture()
        print("PASSED: repository diagnostics, indexed history, schema compatibility and atomic failure preservation")
        print(String(format: "Synthetic repository: %d accounts / %d records / %d bytes; load %.2f ms, commit %.2f ms, indexed reads %.2f ms, scan/sort reads %.2f ms",
                     result.accountCount, result.historyCount, result.fileBytes, result.reloadMilliseconds,
                     result.commitMilliseconds, result.indexedReadMilliseconds, result.scanSortReadMilliseconds))
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw RepositoryPerformanceCheckFailure(description: message) }
    }

    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-storage-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func account(_ index: Int) -> AccountConfiguration {
        AccountConfiguration(displayName: "Synthetic account \(index)", providerKind: .pipio,
                             siteOrigin: URL(string: "https://example.invalid")!, sortOrder: index,
                             createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                             updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private static func record(_ id: UUID, day: Date, amount: Int = 1) -> DailyUsageRecord {
        DailyUsageRecord(accountID: id, day: day,
                         spend: MoneyValue(amount: Decimal(amount), currency: .cny), updatedAt: day)
    }

    private static func snapshot(_ id: UUID) -> ProviderSnapshot {
        ProviderSnapshot(accountID: id, balance: nil, todaySpend: nil, monthSpend: nil,
                         requestCount: nil, capabilities: [], freshness: .fresh,
                         fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
                         rate: AccountRate(accountID: id, source: .providerNativeCurrency, nativeCurrency: .cny))
    }

    private static func write(_ seed: Seed, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(seed).write(to: url)
    }

    private static func advisoryBoundaries() throws {
        var metrics = RepositoryPerformanceDiagnostics()
        try check(metrics.advisories.isEmpty && metrics.commitMilliseconds == nil, "Empty diagnostics must not suggest a threshold breach")
        metrics.fileBytes = 5_000_000
        metrics.maximumHistoryCountPerAccount = 3_000
        metrics.reloadMilliseconds = 200
        metrics.commitMilliseconds = 200
        try check(metrics.advisories.isEmpty, "Suggested thresholds use strict greater-than boundaries")
        metrics.fileBytes += 1
        metrics.maximumHistoryCountPerAccount += 1
        metrics.reloadMilliseconds += 0.1
        metrics.commitMilliseconds = 200.1
        try check(metrics.advisories == [.fileSize, .perAccountHistory, .reloadDuration, .commitDuration], "Every advisory must be independently observable")
    }

    private static func indexedReadsAndCompatibility() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("local.json")
        let empty = try FileLocalRepository(fileURL: url)
        try check(empty.performanceDiagnostics.fileBytes == 0 && empty.performanceDiagnostics.historyCount == 0, "Absent files load empty without writing")
        try check(!FileManager.default.fileExists(atPath: url.path), "Diagnostics must not create a file on read")

        let a = account(0), b = account(1)
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        // Equal days with different values verify the original stable sorting behavior.
        let records = [record(a.id, day: day, amount: 2), record(b.id, day: day),
                       record(a.id, day: day.addingTimeInterval(-86_400)), record(a.id, day: day, amount: 3)]
        try write(Seed(accounts: [a, b], dailyUsage: records), to: url)
        let repository = try FileLocalRepository(fileURL: url)
        let metrics = repository.performanceDiagnostics
        let bytes = try Data(contentsOf: url)
        try check(metrics.accountCount == 2 && metrics.historyCount == 4 && metrics.maximumHistoryCountPerAccount == 3, "Load counts must match all stored records")
        try check(metrics.fileBytes == bytes.count && metrics.reloadMilliseconds >= 0 && metrics.reloadMilliseconds.isFinite, "Load size and monotonic duration must be valid")
        let baseline = records.filter { $0.accountID == a.id }.sorted { $0.day < $1.day }
        for limit: Int? in [nil, -1, 0, 1, 2, 3, 10] {
            let expected = limit.map { $0 > 0 ? Array(baseline.suffix($0)) : baseline } ?? baseline
            try check(try repository.dailyUsage(accountID: a.id, limit: limit) == expected, "Limit, chronological order and equal-day behavior must match the original read")
        }
        try check(try repository.dailyUsage(accountID: UUID(), limit: 30).isEmpty, "Unknown accounts have no history")
        for _ in 0..<10 { _ = try repository.dailyUsage(accountID: a.id, limit: 2) }
        try check(repository.performanceDiagnostics == metrics && Data(contentsOf: url) == bytes, "Reads must not rebuild diagnostics or mutate persisted data")
        let syncBefore = try repository.syncData()
        try check(syncBefore.dailyUsage == records, "The sorted index must not reorder the underlying sync payload")

        let newDay = day.addingTimeInterval(86_400)
        let refreshed = record(a.id, day: newDay, amount: 4)
        try repository.commitRefresh(snapshot(a.id), dailyUsage: refreshed)
        try check(try repository.dailyUsage(accountID: a.id, limit: 1) == [refreshed], "Successful refresh must publish the new history index")
        try check(repository.performanceDiagnostics.lastCommitSucceeded == true && repository.performanceDiagnostics.commitMilliseconds != nil, "Successful writes are timed")
        try check(repository.performanceDiagnostics.fileBytes == Data(contentsOf: url).count, "Committed bytes reflect the written JSON")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        try check(Set(object.keys) == Set(["schemaVersion", "accounts", "snapshots", "dailyUsage", "settings", "deletedAccountIDs"]), "Neither index nor diagnostics may add JSON keys")
        try check(object["schemaVersion"] as? Int == 2, "Schema version stays unchanged")
        let syncEncoder = JSONEncoder()
        let syncKeys = try JSONSerialization.jsonObject(with: syncEncoder.encode(repository.syncData())) as! [String: Any]
        try check(syncKeys["performanceDiagnostics"] == nil && syncKeys["historyByAccount"] == nil, "Diagnostics must not enter sync encoding")
        try check(try FileLocalRepository(fileURL: url).dailyUsage(accountID: a.id, limit: 1) == [refreshed], "Reload must rebuild the index from the committed JSON")

        let replacement = record(a.id, day: newDay, amount: 9)
        let historyCount = repository.performanceDiagnostics.historyCount
        try repository.upsertDailyUsage(replacement)
        try check(try repository.dailyUsage(accountID: a.id, limit: 1) == [replacement], "Upsert must replace an indexed record without keeping stale values")
        try check(repository.performanceDiagnostics.historyCount == historyCount, "Replacement must not increase history counts")
        try repository.upsertSnapshot(snapshot(a.id))
        try check(try repository.dailyUsage(accountID: a.id, limit: 1) == [replacement], "Standalone snapshot commits keep the indexed history intact")
        try repository.deleteAccount(id: b.id)
        try check(try repository.dailyUsage(accountID: b.id, limit: nil).isEmpty, "Deletion removes indexed history")
        let old = record(a.id, day: Date(timeIntervalSince1970: 1_000_000_000))
        try repository.mergeSyncData(RelaySyncData(accounts: [a], snapshots: [], dailyUsage: [old], settings: RelaySettings(historyRetention: .forever)))
        try check(try repository.dailyUsage(accountID: a.id, limit: nil).contains(old), "Merge must publish imported history")
        try repository.updateSettings(RelaySettings(historyRetention: .oneMonth))
        try check(try repository.dailyUsage(accountID: a.id, limit: nil).isEmpty, "Retention pruning must remove old indexed records")
        try check(repository.performanceDiagnostics.historyCount == 0, "Pruning refreshes committed counts")

        try Data("{}".utf8).write(to: url)
        let legacy = try FileLocalRepository(fileURL: url)
        try check(try legacy.fetchAccounts().isEmpty && legacy.dailyUsage(accountID: a.id, limit: nil).isEmpty, "Legacy JSON defaults remain compatible")
        for (invalid, expected) in [("{", LocalRepositoryError.corruptData), ("{\"schemaVersion\":3}", .unsupportedVersion)] {
            try Data(invalid.utf8).write(to: url)
            do {
                _ = try FileLocalRepository(fileURL: url)
                throw RepositoryPerformanceCheckFailure(description: "Corrupt or future-schema JSON was accepted")
            } catch let error as LocalRepositoryError {
                try check(error == expected, "Corruption and unsupported schema must be distinguished")
            }
        }
    }

    private static func failedCommitsKeepCommittedState() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("local.json")
        let backup = root.appendingPathComponent("committed.json")
        let a = account(0)
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let original = record(a.id, day: day)
        try write(Seed(accounts: [a], dailyUsage: [original]), to: url)
        let repository = try FileLocalRepository(fileURL: url)
        let before = try repository.syncData()
        let beforeMetrics = repository.performanceDiagnostics
        let beforeBytes = try Data(contentsOf: url)
        try FileManager.default.moveItem(at: url, to: backup)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let next = record(a.id, day: day.addingTimeInterval(86_400))
        let operations: [() throws -> Void] = [
            { try repository.upsertAccount(account(1)) },
            { try repository.upsertSnapshot(snapshot(a.id)) },
            { try repository.commitRefresh(snapshot(a.id), dailyUsage: next) },
            { try repository.upsertDailyUsage(next) },
            { try repository.updateSettings(RelaySettings(historyRetention: .oneMonth)) },
            { try repository.deleteAccount(id: a.id) },
            { try repository.mergeSyncData(RelaySyncData(accounts: [a], snapshots: [], dailyUsage: [next], settings: RelaySettings(historyRetention: .forever))) }
        ]
        for operation in operations {
            do {
                try operation()
                throw RepositoryPerformanceCheckFailure(description: "Commit to a directory unexpectedly succeeded")
            } catch LocalRepositoryError.unavailable {}
            let after = try repository.syncData()
            try check(after.accounts == before.accounts && after.snapshots == before.snapshots && after.dailyUsage == before.dailyUsage && after.settings == before.settings && after.settingsUpdatedAt == before.settingsUpdatedAt && after.deletedAccountIDs == before.deletedAccountIDs, "Failed writes must preserve every committed state field")
            try check(try repository.dailyUsage(accountID: a.id, limit: nil) == [original], "Failed writes must not invalidate or advance the index")
            let metrics = repository.performanceDiagnostics
            try check(metrics.accountCount == beforeMetrics.accountCount && metrics.historyCount == beforeMetrics.historyCount && metrics.maximumHistoryCountPerAccount == beforeMetrics.maximumHistoryCountPerAccount && metrics.fileBytes == beforeMetrics.fileBytes && metrics.reloadMilliseconds == beforeMetrics.reloadMilliseconds, "Failed candidates must not change committed capacity observations")
            try check(metrics.lastCommitSucceeded == false && (metrics.commitMilliseconds ?? -1) >= 0, "Failed attempts expose only duration and outcome")
            try check(try Data(contentsOf: backup) == beforeBytes, "Committed bytes must remain intact")
        }
        try check(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["committed.json", "local.json"], "Failed commits must not leave temporary files")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: backup, to: url)
        try repository.commitRefresh(snapshot(a.id), dailyUsage: next)
        try check(try repository.dailyUsage(accountID: a.id, limit: 1) == [next], "Recovery publishes new history after a successful commit")
        try check(repository.performanceDiagnostics.lastCommitSucceeded == true, "Recovery updates the attempt outcome")
    }

    /// No timing assertion: machine load varies. This returns reproducible synthetic
    /// measurements and verifies equivalent results instead of setting a flaky speed gate.
    static func performanceFixture(accountCount: Int = 8, historyPerAccount: Int = 3_001, readPasses: Int = 10) throws -> FixtureResult {
        try check(accountCount > 0 && historyPerAccount > 0 && readPasses > 0, "Fixture dimensions must be positive")
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("local.json")
        let accounts = (0..<accountCount).map(account)
        let startDay = Date(timeIntervalSince1970: 1_000_000_000)
        let records = (0..<historyPerAccount).reversed().flatMap { offset in
            accounts.map { record($0.id, day: startDay.addingTimeInterval(Double(offset) * 86_400)) }
        }
        try write(Seed(accounts: accounts, dailyUsage: records), to: url)
        let repository = try FileLocalRepository(fileURL: url)
        try check(repository.performanceDiagnostics.maximumHistoryCountPerAccount == historyPerAccount, "Large fixture counts remain correct")
        if repository.performanceDiagnostics.fileBytes > RepositoryPerformanceDiagnostics.suggestedFileBytes {
            try check(repository.performanceDiagnostics.advisories.contains(.fileSize), "A synthetic file size breach must surface its advisory")
        }
        if historyPerAccount > RepositoryPerformanceDiagnostics.suggestedHistoryCountPerAccount {
            try check(repository.performanceDiagnostics.advisories.contains(.perAccountHistory), "A real synthetic capacity breach must surface its advisory")
        }
        var scanResults: [[DailyUsageRecord]] = []
        var started = RepositoryPerformanceClock.now()
        for _ in 0..<readPasses {
            for account in accounts {
                scanResults.append(Array(records.filter { $0.accountID == account.id }.sorted { $0.day < $1.day }.suffix(30)))
            }
        }
        let scanTime = RepositoryPerformanceClock.elapsedMilliseconds(since: started)
        var indexedResults: [[DailyUsageRecord]] = []
        started = RepositoryPerformanceClock.now()
        for _ in 0..<readPasses {
            for account in accounts { indexedResults.append(try repository.dailyUsage(accountID: account.id, limit: 30)) }
        }
        let indexedTime = RepositoryPerformanceClock.elapsedMilliseconds(since: started)
        try check(indexedResults == scanResults, "Large fixture indexed results must equal scan/sort results")
        try repository.commitRefresh(snapshot(accounts[0].id), dailyUsage: nil)
        try check(try repository.dailyUsage(accountID: accounts[0].id, limit: 30) == indexedResults[0], "Snapshot-only commits preserve history")
        let metrics = repository.performanceDiagnostics
        return FixtureResult(accountCount: metrics.accountCount, historyCount: metrics.historyCount,
                             fileBytes: metrics.fileBytes, reloadMilliseconds: metrics.reloadMilliseconds,
                             commitMilliseconds: metrics.commitMilliseconds ?? 0,
                             indexedReadMilliseconds: indexedTime, scanSortReadMilliseconds: scanTime)
    }
}
