import Foundation

private struct SyncSafetyFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
enum SyncSafetyChecks {
    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw SyncSafetyFailure(description: message) }
    }
    private static func encode(_ payload: RelaySyncData) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(RelaySyncData(schemaVersion: payload.schemaVersion, exportedAt: Date(timeIntervalSince1970: 0),
                                              accounts: payload.accounts, snapshots: payload.snapshots, dailyUsage: payload.dailyUsage,
                                              settings: payload.settings, settingsUpdatedAt: payload.settingsUpdatedAt,
                                              deletedAccountIDs: payload.deletedAccountIDs))
    }
    private static func rejects(_ body: () throws -> Void) throws {
        do { try body() }
        catch { return }
        throw SyncSafetyFailure(description: "Expected failed sync")
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-sync-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = InMemoryLocalRepository()
        let account = AccountConfiguration(displayName: "Local", providerKind: .pipio,
                                           siteOrigin: URL(string: "https://example.invalid")!, updatedAt: Date(timeIntervalSince1970: 100))
        try repo.upsertAccount(account)
        let url = root.appendingPathComponent(FileSyncService.fileName)
        let local = try repo.syncData()
        var newer = account; newer.displayName = "Remote newer"; newer.updatedAt = Date(timeIntervalSince1970: 200)
        let remote = RelaySyncData(accounts: [newer], snapshots: [], dailyUsage: [], settings: RelaySettings())
        let bytes = try encode(remote); try bytes.write(to: url)
        let failedCoordination: FileSyncService.Coordination = { _, _, _ in throw FileSyncError.coordinationFailed }
        try rejects { try FileSyncService.exchange(repository: repo, directory: root, writeBack: true, coordination: failedCoordination) }
        try check(FileSyncService.lastSyncStatus == .failed && !FileSyncService.performanceDiagnostics.succeeded, "Coordination failure is reported as failed")
        try check(try encode(repo.syncData()) == encode(local), "Accessor bypass must never merge local data after coordination failure")
        try check(try Data(contentsOf: url) == bytes, "No fallback write after coordination failure")
        try FileManager.default.removeItem(at: url)
        try rejects { try FileSyncService.exchange(repository: repo, directory: root, writeBack: true, coordination: failedCoordination) }
        try check(!FileManager.default.fileExists(atPath: url.path), "Failed first-write coordination must not create a placeholder outside its scope")
        try bytes.write(to: url)
        let failedWrite: (Data, URL) throws -> Void = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        try rejects {
            try FileSyncService.exchange(repository: repo, directory: root, writeBack: true,
                                         coordination: FileSyncService.uncoordinatedFixture, write: failedWrite)
        }
        try check(FileSyncService.lastSyncStatus == .failed && !FileSyncService.performanceDiagnostics.succeeded, "Local merge plus cloud write failure is not sync success")
        try check(try repo.account(id: account.id)?.displayName == newer.displayName, "Local merge remains usable after failed remote write")
        try check(try Data(contentsOf: url) == bytes, "Failed write preserves remote bytes")
        try FileSyncService.exchange(repository: repo, directory: root, writeBack: true, coordination: FileSyncService.uncoordinatedFixture)
        try check(FileSyncService.lastSyncStatus == .merged && FileSyncService.performanceDiagnostics.succeeded, "Retry can complete after a partial exchange")
        try check(try repo.fetchAccounts().count == 1, "Retry is idempotent")

        let report = SyncConflictReport(status: .conflicted, local: SyncCandidate(source: .local, fileURL: root.appendingPathComponent("local.json"), data: local, modifiedAt: Date()),
                                        remoteCandidates: [SyncCandidate(source: .remote, fileURL: url, data: remote, modifiedAt: Date())], conflicts: [], mergedData: nil, requiresUserAction: true)
        let beforeResolution = try encode(repo.syncData()), beforeRemote = try Data(contentsOf: url)
        try rejects { _ = try FileSyncService.resolve(repository: repo, report: report, decision: .keepLocal, coordination: failedCoordination) }
        try check(try encode(repo.syncData()) == beforeResolution && Data(contentsOf: url) == beforeRemote, "Failed resolution coordination cannot mutate local or remote data")
        try check(FileSyncService.lastConflictReport != nil && FileSyncService.lastSyncStatus == .failed, "Failed resolution retains the candidate report")
        try rejects { _ = try FileSyncService.resolve(repository: repo, report: report, decision: .keepLocal,
                                                    coordination: FileSyncService.uncoordinatedFixture, write: failedWrite) }
        try check(FileSyncService.lastConflictReport != nil, "Partial resolution keeps report for retry")
        _ = try FileSyncService.resolve(repository: repo, report: report, decision: .keepLocal, coordination: FileSyncService.uncoordinatedFixture)
        try check(FileSyncService.lastConflictReport == nil && FileSyncService.lastSyncStatus == .merged, "Explicit retry resolves once fully durable")
        print("PASSED: no coordination bypass/placeholder, partial sync and resolution failures, preserved candidates and idempotent retry")
        try await backgroundSafety(root)
        try await performanceSamples(root)
    }

    private static func backgroundSafety(_ root: URL) async throws {
        let directory = root.appendingPathComponent("background")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(FileSyncService.fileName)
        let repo = InMemoryLocalRepository()
        var account = AccountConfiguration(displayName: "Original", providerKind: .pipio,
                                           siteOrigin: URL(string: "https://example.invalid")!, updatedAt: Date(timeIntervalSince1970: 100))
        try repo.upsertAccount(account)
        try encode(repo.syncData()).write(to: url)
        let gate = SyncWorkGate()
        defer { gate.release() }
        let coordination: FileSyncService.Coordination = { url, _, accessor in
            gate.waitOnce()
            accessor(url)
        }
        let syncing = Task { try await FileSyncService.exchangeAsync(repository: repo, directory: directory, coordination: coordination) }
        for _ in 0..<20_000 {
            if gate.hasStarted { break }
            await Task.yield()
        }
        try check(gate.hasStarted && !gate.wasMainThread, "File coordination is running off the main thread")
        // MainActor is responsive while the worker is blocked on coordination.
        account.displayName = "Edited during coordination"
        account.updatedAt = Date(timeIntervalSince1970: 200)
        try repo.upsertAccount(account)
        gate.release()
        let status = try await syncing.value
        try check(try status == .merged && repo.account(id: account.id)?.displayName == account.displayName,
                  "Stale background data cannot overwrite an in-flight local edit")
        var deletedOnce = false
        _ = try await FileSyncService.exchangeAsync(repository: repo, directory: directory,
            coordination: FileSyncService.uncoordinatedFixture, beforeCommit: {
                if !deletedOnce { deletedOnce = true; try! repo.deleteAccount(id: account.id) }
            })
        try check(try repo.fetchAccounts().isEmpty && !repo.syncData().deletedAccountIDs.isEmpty,
                  "Background merge cannot resurrect an account deleted during preparation")

        let fresh = AccountConfiguration(displayName: "New remote", providerKind: .pipio,
                                         siteOrigin: URL(string: "https://example.invalid")!, updatedAt: Date())
        var changedOnce = false
        _ = try await FileSyncService.exchangeAsync(repository: repo, directory: directory,
            coordination: FileSyncService.uncoordinatedFixture, beforeWrite: {
                if !changedOnce {
                    changedOnce = true
                    try! encode(RelaySyncData(accounts: [fresh], snapshots: [], dailyUsage: [], settings: RelaySettings())).write(to: url)
                }
            })
        try check(try repo.account(id: fresh.id) != nil && repo.account(id: account.id) == nil,
                  "Remote change between read/write forces remerge and retains local deletion")
        let before = try Data(contentsOf: url)
        do {
            _ = try await FileSyncService.exchangeAsync(repository: repo, directory: directory,
                coordination: { _, _, _ in throw FileSyncError.coordinationFailed })
            throw SyncSafetyFailure(description: "Async coordination failure succeeded")
        } catch FileSyncError.coordinationFailed {}
        try check(try Data(contentsOf: url) == before && FileSyncService.lastSyncStatus == .failed,
                  "Async coordination failure preserves remote bytes and failure status")
        let cancelGate = SyncWorkGate()
        defer { cancelGate.release() }
        let beforeCancel = try encode(repo.syncData())
        let cancelling = Task {
            try await FileSyncService.exchangeAsync(repository: repo, directory: directory,
                coordination: { url, _, accessor in cancelGate.waitOnce(); accessor(url) })
        }
        for _ in 0..<20_000 { if cancelGate.hasStarted { break }; await Task.yield() }
        try check(cancelGate.hasStarted, "Cancellation fixture reached coordination")
        cancelling.cancel()
        cancelGate.release()
        do { _ = try await cancelling.value; throw SyncSafetyFailure(description: "Cancelled sync completed") }
        catch is CancellationError {}
        try check(try encode(repo.syncData()) == beforeCancel && Data(contentsOf: url) == before,
                  "Cancelled background preparation cannot commit either copy")
        let current = try repo.syncData()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(RelaySyncData.self, from: Data(contentsOf: url))
        let candidate = SyncCandidate(source: .remote, fileURL: url, data: persisted, modifiedAt: Date())
        let report = SyncConflictReport(status: .conflicted,
            local: SyncCandidate(source: .local, fileURL: directory.appendingPathComponent("local.json"), data: current, modifiedAt: Date()),
            remoteCandidates: [candidate], conflicts: [], mergedData: nil, requiresUserAction: true)
        do {
            try await FileSyncService.resolveAsync(repository: repo, report: report, decision: .keepLocal,
                coordination: FileSyncService.uncoordinatedFixture,
                write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
            throw SyncSafetyFailure(description: "Async failed resolution succeeded")
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {}
        try check(FileSyncService.lastConflictReport != nil && FileSyncService.lastSyncStatus == .failed,
                  "Async resolution keeps candidates after local commit and failed cloud write")
        try await FileSyncService.resolveAsync(repository: repo, report: report, decision: .keepLocal,
                                               coordination: FileSyncService.uncoordinatedFixture)
        try check(FileSyncService.lastConflictReport == nil && FileSyncService.lastSyncStatus == .merged,
                  "Async resolution retry clears report only after remote write succeeds")
        let changed = RelaySyncData(accounts: [], snapshots: [], dailyUsage: [], settings: RelaySettings())
        try encode(changed).write(to: url)
        do {
            try await FileSyncService.resolveAsync(repository: repo, report: report, decision: .keepLocal,
                                                   coordination: FileSyncService.uncoordinatedFixture)
            throw SyncSafetyFailure(description: "Changed remote report was accepted")
        } catch FileSyncError.dataChanged {}
        try check(try repo.account(id: fresh.id) != nil && Data(contentsOf: url) == encode(changed),
                  "Changed remote candidates require a fresh decision without overwrite")
        print("PASSED: main-actor progress during slow background coordination, local edit/delete rejection, remote remerge and async failure protection")
    }

    private static func performanceSamples(_ root: URL) async throws {
        for (count, historyPerAccount) in [(1, 30), (10, 30), (50, 30), (8, 3_001)] {
            let directory = root.appendingPathComponent("sample-\(count)-\(historyPerAccount)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let localURL = directory.appendingPathComponent("local.json")
            let accounts = (0..<count).map { AccountConfiguration(displayName: "Fixture \($0)", providerKind: .pipio,
                                                                 siteOrigin: URL(string: "https://example.invalid")!) }
            let history = accounts.flatMap { account in
                (0..<historyPerAccount).map { offset in
                    DailyUsageRecord(accountID: account.id, day: Date(timeIntervalSince1970: 1_000_000_000 + Double(offset * 86_400)),
                                     spend: MoneyValue(amount: 1, currency: .cny))
                }
            }
            let data = RelaySyncData(accounts: accounts, snapshots: [], dailyUsage: history, settings: RelaySettings(historyRetention: .forever))
            try encode(data).write(to: localURL)
            try encode(data).write(to: directory.appendingPathComponent(FileSyncService.fileName))
            let repo = try FileLocalRepository(fileURL: localURL)
            _ = try await FileSyncService.exchangeAsync(repository: repo, directory: directory, coordination: FileSyncService.uncoordinatedFixture)
            let metrics = FileSyncService.performanceDiagnostics
            try check(metrics.succeeded && metrics.payloadBytes > 0 && metrics.totalMilliseconds >= metrics.coordinationMilliseconds, "Measured successful sample")
            print(String(format: "Synthetic async sync: %d accounts / %d records / %d bytes; total %.2f ms, coordination %.2f ms, read/merge %.2f ms, local commit %.2f ms, encode %.2f ms, write %.2f ms",
                         count, history.count, metrics.payloadBytes, metrics.totalMilliseconds, metrics.coordinationMilliseconds,
                         metrics.readMergeMilliseconds, metrics.localCommitMilliseconds, metrics.encodeMilliseconds, metrics.writeMilliseconds))
        }
    }
}

private final class SyncWorkGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false
    private var mainThread = false
    var hasStarted: Bool { condition.lock(); defer { condition.unlock() }; return started }
    var wasMainThread: Bool { condition.lock(); defer { condition.unlock() }; return mainThread }
    func waitOnce() {
        condition.lock()
        defer { condition.unlock() }
        guard !started else { return }
        started = true
        mainThread = Thread.isMainThread
        while !released { condition.wait() }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}
