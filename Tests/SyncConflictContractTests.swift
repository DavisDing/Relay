import Foundation

private enum ContractTestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

private struct FailingMerger: SyncDataMerging {
    func merge(_ local: RelaySyncData, _ remote: RelaySyncData) throws -> RelaySyncData {
        throw LocalRepositoryError.corruptData
    }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ContractTestFailure.failed(message) }
}

private func data(account: AccountConfiguration) -> RelaySyncData {
    RelaySyncData(
        accounts: [account],
        snapshots: [],
        dailyUsage: [],
        settings: RelaySettings()
    )
}

private func account(_ name: String, id: UUID = UUID(), credentialReference: String? = nil) -> AccountConfiguration {
    AccountConfiguration(
        id: id,
        displayName: name,
        providerKind: .pipio,
        siteOrigin: URL(string: "https://example.invalid")!,
        credentialReference: credentialReference
    )
}

@main
struct SyncConflictContractTests {
    @MainActor
    static func main() throws {
        try sanitizedCandidateNeverSerializesCredentialMaterial()
        try unresolvedConflictRetainsBothSidesUntilDecision()
        try mergeFailureRemainsLocalFirstAndAllowsKeepRemote()
        try unavailableSyncDoesNotBlockLocalState()
        try explicitResolutionPersistsPrimaryWithoutDeletingCandidate()
        print("SyncConflictContractTests: PASS (5 cases)")
    }

    private static func candidate(_ source: SyncSource, _ data: RelaySyncData, at date: Date) -> SyncCandidate {
        SyncCandidate(
            source: source,
            fileURL: URL(fileURLWithPath: "/tmp/relay-\(date.timeIntervalSince1970).json"),
            data: data,
            modifiedAt: date
        )
    }

    private static func sanitizedCandidateNeverSerializesCredentialMaterial() throws {
        let id = UUID()
        let candidate = candidate(
            .local,
            data(account: account("local", id: id, credentialReference: "real-token-must-not-sync")),
            at: Date(timeIntervalSince1970: 1)
        )
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(candidate.data)
        let text = String(decoding: encoded, as: UTF8.self)
        try check(RelaySyncDataSafety.isSafe(candidate.data), "candidate must have a safe credential projection")
        try check(!text.contains("real-token-must-not-sync"), "credential material must not be serialized")
        try check(candidate.data.accounts.first?.credentialReference == id.uuidString, "sync reference must be account-local UUID")
    }

    private static func unresolvedConflictRetainsBothSidesUntilDecision() throws {
        let id = UUID()
        let local = candidate(.local, data(account: account("local", id: id)), at: Date(timeIntervalSince1970: 10))
        let remoteA = candidate(.remote, data(account: account("remote-a", id: id)), at: Date(timeIntervalSince1970: 20))
        let remoteB = candidate(.conflictCopy(URL(fileURLWithPath: "/tmp/relay-conflict.json")), data(account: account("remote-b", id: id)), at: Date(timeIntervalSince1970: 30))
        let service = SyncConflictService()
        let state = service.inspect(local: local, remoteCandidates: [remoteA, remoteB])
        try check(state.status == .conflicted, "multiple remote candidates must remain conflicted")
        try check(state.report?.requiresUserAction == true, "conflict must require an explicit decision")
        try check(state.report?.conflicts.count == 2, "both remote candidates must be preserved in the report")
        try check(state.report?.mergedData != nil, "deterministic merge may be offered without applying it")
        try check(state.report?.remoteCandidates.count == 2, "report must retain both remote candidates")
        if let report = state.report {
            let resolution = try service.resolve(report: report, decision: .acceptMerged)
            try check(resolution.preservedCandidates.count == 2, "resolution must not delete conflict candidates")
            try check(resolution.decision == .acceptMerged, "resolution must be created only after user decision")
        } else {
            throw ContractTestFailure.failed("expected a conflict report")
        }
    }

    private static func mergeFailureRemainsLocalFirstAndAllowsKeepRemote() throws {
        let local = candidate(.local, data(account: account("local")), at: Date(timeIntervalSince1970: 10))
        let remote = candidate(.remote, data(account: account("remote")), at: Date(timeIntervalSince1970: 20))
        let service = SyncConflictService(merger: FailingMerger())
        let state = service.inspect(local: local, remoteCandidates: [remote])
        try check(state.status == .conflicted, "merge failure must become an explicit conflict")
        try check(state.report?.mergedData == nil, "failed merge must not fabricate merged data")
        if let report = state.report {
            let resolution = try service.resolve(report: report, decision: .keepRemote)
            try check(resolution.selectedRemoteCandidate?.id == remote.id, "keep remote must select the available remote candidate")
            try check(resolution.preservedCandidates.count == 1, "remote candidate remains preserved after decision")
        } else {
            throw ContractTestFailure.failed("expected a conflict report after merge failure")
        }
    }

    @MainActor
    private static func explicitResolutionPersistsPrimaryWithoutDeletingCandidate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-sync-resolution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = UUID()
        let localData = data(account: account("local-selected", id: id))
        let remoteData = data(account: account("remote-primary", id: id))
        let conflictData = data(account: account("remote-conflict", id: id))
        let primaryURL = directory.appendingPathComponent(FileSyncService.fileName)
        let conflictURL = directory.appendingPathComponent("relay-sync-v1.conflict.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(remoteData).write(to: primaryURL)
        try encoder.encode(conflictData).write(to: conflictURL)

        let local = SyncCandidate(source: .local, fileURL: directory.appendingPathComponent("local.json"), data: localData, modifiedAt: Date(timeIntervalSince1970: 10))
        let primary = SyncCandidate(source: .remote, fileURL: primaryURL, data: remoteData, modifiedAt: Date(timeIntervalSince1970: 20))
        let conflict = SyncCandidate(source: .conflictCopy(conflictURL), fileURL: conflictURL, data: conflictData, modifiedAt: Date(timeIntervalSince1970: 30))
        let state = SyncConflictService().inspect(local: local, remoteCandidates: [primary, conflict])
        guard let report = state.report else { throw ContractTestFailure.failed("expected a report for explicit resolution") }

        let repository = InMemoryLocalRepository()
        try repository.mergeSyncData(localData)
        let result = try FileSyncService.resolve(repository: repository, report: report, decision: .keepLocal)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(RelaySyncData.self, from: Data(contentsOf: primaryURL))

        let localAfterResolution = try repository.syncData()
        try check(result.decision == .keepLocal, "explicit decision must be returned")
        try check(localAfterResolution.accounts.first?.displayName == "local-selected", "selected data must be applied locally")
        try check(persisted.accounts.first?.displayName == "local-selected", "selected data must replace the primary sync file")
        try check(FileManager.default.fileExists(atPath: conflictURL.path), "resolution must not delete the conflict candidate")
    }

    private static func unavailableSyncDoesNotBlockLocalState() throws {
        let local = candidate(.local, data(account: account("local")), at: Date(timeIntervalSince1970: 10))
        let service = SyncConflictService()
        let state = service.inspect(
            local: local,
            remoteCandidates: [],
            availability: .unavailable(reason: "iCloud Drive 目录暂不可访问")
        )
        try check(state.status == .unavailable, "unavailable sync must be visible as unavailable")
        try check(state.localDataAvailable, "unavailable sync must retain local availability")
        try check(state.availabilityMessage != nil, "unavailable sync must expose a user-safe message")
    }
}
