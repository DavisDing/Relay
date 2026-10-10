import Foundation

/// Best-effort iCloud Drive ordinary-file sync for non-secret Relay data.
/// Credentials are structurally absent from RelaySyncData and are never written here.
/// The selected directory is kept as a security-scoped bookmark, not reconstructed
/// from a localized iCloud Drive path.
public enum FileSyncService {
    public static let fileName = "relay-sync-v1.json"
    @MainActor public private(set) static var lastSyncStatus: SyncStatus = .idle
    @MainActor public private(set) static var lastConflictReport: SyncConflictReport?
    /// Injection is internal and explicit; production always uses NSFileCoordinator.
    typealias Coordination = (URL, Bool, (URL) -> Void) throws -> Void
    static let uncoordinatedFixture: Coordination = { url, _, accessor in accessor(url) }
    @MainActor public private(set) static var performanceDiagnostics = SyncPerformanceDiagnostics()

    @MainActor private static func coordinate(_ url: URL, writing: Bool, using fixture: Coordination?, accessor: @escaping (URL) -> Void) throws {
        let start = RepositoryPerformanceClock.now()
        var accessorStart: UInt64?
        var accessorEnd: UInt64?
        defer {
            let total = RepositoryPerformanceClock.elapsedMilliseconds(since: start)
            let work = accessorStart.flatMap { beginning in accessorEnd.map { Double($0 - beginning) / 1_000_000 } } ?? 0
            performanceDiagnostics.coordinationMilliseconds += max(0, total - work)
        }
        var didRun = false
        let measured: (URL) -> Void = { coordinatedURL in
            didRun = true
            accessorStart = RepositoryPerformanceClock.now()
            accessor(coordinatedURL)
            accessorEnd = RepositoryPerformanceClock.now()
        }
        if let fixture { try fixture(url, writing, measured) }
        else {
            var error: NSError?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            if writing {
                if FileManager.default.fileExists(atPath: url.path) {
                    coordinator.coordinate(writingItemAt: url, options: [], error: &error, byAccessor: measured)
                } else {
                    coordinator.coordinate(writingItemAt: url.deletingLastPathComponent(), options: [], error: &error) { directory in
                        measured(directory.appendingPathComponent(url.lastPathComponent))
                    }
                }
            }
            else { coordinator.coordinate(readingItemAt: url, options: [], error: &error, byAccessor: measured) }
            if error != nil { throw FileSyncError.coordinationFailed }
        }
        guard didRun else { throw FileSyncError.coordinationFailed }
    }

    private static let worker = SyncFileWorker()

    /// UI synchronization awaits serial file work. Before committing its result,
    /// compare the full non-secret source snapshot with current local content.
    @MainActor
    static func exchangeAsync(repository: any LocalRepository, directory: URL,
                              isEnabled: () -> Bool = { true },
                              coordination: Coordination? = nil,
                              write: ((Data, URL) throws -> Void)? = nil,
                              beforeCommit: (() -> Void)? = nil,
                              beforeWrite: (() -> Void)? = nil) async throws -> SyncStatus {
        let start = RepositoryPerformanceClock.now()
        performanceDiagnostics = SyncPerformanceDiagnostics()
        lastSyncStatus = .uploading
        defer { performanceDiagnostics.totalMilliseconds = RepositoryPerformanceClock.elapsedMilliseconds(since: start) }
        do {
            // Bound churn retries so sustained edits cannot spin forever.
            for _ in 0..<3 {
                try Task.checkCancellation()
                guard isEnabled() else { lastSyncStatus = .idle; return .idle }
                let local = try repository.syncData()
                var prepared = try await worker.prepare(local: local, directory: directory, coordination: coordination)
                try Task.checkCancellation()
                guard isEnabled() else { lastSyncStatus = .idle; return .idle }
                beforeCommit?()
                guard try repository.syncData().hasSameContent(as: local) else { continue }
                if let conflict = prepared.conflict {
                    lastConflictReport = conflict
                    lastSyncStatus = .conflicted
                    performanceDiagnostics = prepared.diagnostics
                    return .conflicted
                }
                let commitStarted = RepositoryPerformanceClock.now()
                guard try repository.applyPreparedSyncData(prepared.data, expected: local) else { continue }
                prepared.diagnostics.localCommitMilliseconds = RepositoryPerformanceClock.elapsedMilliseconds(since: commitStarted)
                performanceDiagnostics = prepared.diagnostics
                let committed = try repository.syncData()
                beforeWrite?()
                guard isEnabled() else { lastSyncStatus = .idle; return .idle }
                let written = try await worker.write(local: committed, prepared: prepared, directory: directory,
                                                     coordination: coordination, write: write)
                performanceDiagnostics = written.diagnostics
                try Task.checkCancellation()
                if written.remoteChanged { continue }
                guard try repository.syncData().hasSameContent(as: committed) else { continue }
                lastConflictReport = nil
                lastSyncStatus = .merged
                performanceDiagnostics.succeeded = true
                return .merged
            }
            throw FileSyncError.dataChanged
        } catch {
            lastSyncStatus = .failed
            performanceDiagnostics.succeeded = false
            throw error
        }
    }

    @MainActor
    static func resolveAsync(repository: any LocalRepository, report: SyncConflictReport,
                             decision: SyncConflictDecision, isEnabled: () -> Bool = { true },
                             coordination: Coordination? = nil,
                             write: ((Data, URL) throws -> Void)? = nil) async throws {
        guard let directory = report.remoteCandidates.first(where: { $0.source == .remote })?.fileURL.deletingLastPathComponent()
        else { throw SyncConflictError.remoteCandidateUnavailable }
        let start = RepositoryPerformanceClock.now()
        lastConflictReport = report
        lastSyncStatus = .uploading
        performanceDiagnostics = SyncPerformanceDiagnostics()
        defer { performanceDiagnostics.totalMilliseconds = RepositoryPerformanceClock.elapsedMilliseconds(since: start) }
        do {
            let local = try repository.syncData()
            var prepared = try await worker.prepare(local: local, directory: directory, coordination: coordination)
            let resolved = try await worker.resolve(report: report, decision: decision, current: local, prepared: prepared)
            try Task.checkCancellation()
            guard isEnabled() else { throw CancellationError() }
            let commitStart = RepositoryPerformanceClock.now()
            guard try repository.applyPreparedSyncData(resolved, expected: local) else { throw FileSyncError.dataChanged }
            prepared.diagnostics.localCommitMilliseconds = RepositoryPerformanceClock.elapsedMilliseconds(since: commitStart)
            performanceDiagnostics = prepared.diagnostics
            let written = try await worker.write(local: repository.syncData(), prepared: prepared, directory: directory,
                                                 coordination: coordination, write: write)
            performanceDiagnostics = written.diagnostics
            guard !written.remoteChanged else { throw FileSyncError.dataChanged }
            lastConflictReport = nil
            lastSyncStatus = .merged
            performanceDiagnostics.succeeded = true
        } catch {
            lastSyncStatus = .failed
            performanceDiagnostics.succeeded = false
            throw error
        }
    }

    private static let bookmarkDefaultsKey = "relay.iCloudSyncDirectoryBookmark"

    /// Stores the directory confirmed by the user in the system directory picker.
    /// The bookmark is local-only metadata and never enters RelaySyncData.
    @MainActor
    public static func setSyncDirectory(_ directory: URL) throws {
        guard directory.isFileURL else { throw FileSyncError.invalidDirectory }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw FileSyncError.invalidDirectory }
        let bookmark = try directory.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: [.isDirectoryKey], relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: bookmarkDefaultsKey)
    }

    @MainActor
    public static func clearSyncDirectory() {
        UserDefaults.standard.removeObject(forKey: bookmarkDefaultsKey)
    }

    @MainActor
    public static func configuredDirectoryURL() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkDefaultsKey) else { return nil }
        var isStale = false
        guard let directory = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        if isStale,
           let refreshed = try? directory.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: [.isDirectoryKey], relativeTo: nil) {
            UserDefaults.standard.set(refreshed, forKey: bookmarkDefaultsKey)
        }
        return directory
    }

    @MainActor
    public static func hasConfiguredDirectory() -> Bool {
        configuredDirectoryURL() != nil
    }

    @MainActor
    public static func importIfAvailable(repository: any LocalRepository) throws {
        guard let directory = configuredDirectoryURL() else { throw FileSyncError.invalidDirectory }
        try exchange(repository: repository, directory: directory, writeBack: false)
    }

    @MainActor
    public static func exportIfEnabled(repository: any LocalRepository, settings: RelaySettings) throws {
        guard settings.iCloudFileSyncEnabled else { return }
        guard let directory = configuredDirectoryURL() else { throw FileSyncError.invalidDirectory }
        try exchange(repository: repository, directory: directory, writeBack: true)
    }

    /// Read, merge and replace under ONE coordination scope. This is also the
    /// test seam for two independent repositories sharing an ordinary folder.
    @MainActor
    static func exchange(repository: any LocalRepository, directory: URL, writeBack: Bool, coordination: Coordination? = nil, write: ((Data, URL) throws -> Void)? = nil) throws {
        let started = RepositoryPerformanceClock.now()
        performanceDiagnostics = SyncPerformanceDiagnostics()
        defer {
            performanceDiagnostics.totalMilliseconds = RepositoryPerformanceClock.elapsedMilliseconds(since: started)
            performanceDiagnostics.succeeded = lastSyncStatus == .merged
        }
        lastSyncStatus = writeBack ? .uploading : .downloading
        lastConflictReport = nil
        defer {
            if lastSyncStatus == (writeBack ? .uploading : .downloading) {
                lastSyncStatus = .merged
            }
        }
        do {
            try withSecurityScopedAccess(directory) {
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw FileSyncError.invalidDirectory
            }
            let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
            var operationError: Error?
            let operation: (URL) -> Void = { coordinatedURL in
                do {
                    let readStart = RepositoryPerformanceClock.now()
                    let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: coordinatedURL) ?? []
                    let localData = try repository.syncData()
                    var merged = localData
                    var remoteCandidates: [SyncCandidate] = []
                    if let primary = try readPayloadIfPresent(at: coordinatedURL) {
                        remoteCandidates.append(SyncCandidate(
                            source: .remote,
                            fileURL: coordinatedURL,
                            data: primary,
                            modifiedAt: (try? coordinatedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                        ))
                        merged = try SyncMerge.merge(merged, primary)
                    }
                    // Do not discard an unreadable or unknown-version conflict.
                    // Validate ALL versions before changing the local repository.
                    for version in versions {
                        guard let payload = try readPayloadIfPresent(at: version.url) else {
                            throw FileSyncError.unreadableConflict
                        }
                        remoteCandidates.append(SyncCandidate(
                            source: .conflictCopy(version.url),
                            fileURL: version.url,
                            data: payload,
                            modifiedAt: version.modificationDate ?? Date.distantPast
                        ))
                        merged = try SyncMerge.merge(merged, payload)
                    }
                    if remoteCandidates.count > 1 {
                        let localCandidate = SyncCandidate(
                            source: .local,
                            fileURL: repositoryURL(repository),
                            data: localData,
                            modifiedAt: Date()
                        )
                        let conflictState = SyncConflictService().inspect(
                            local: localCandidate,
                            remoteCandidates: remoteCandidates,
                            availability: .available
                        )
                        if conflictState.status == .conflicted, let report = conflictState.report {
                            // A conflicted exchange is read-only until the user
                            // chooses a decision. Do not mutate the local
                            // repository or overwrite the primary remote file.
                            lastConflictReport = report
                            lastSyncStatus = .conflicted
                            return
                        }
                    }
                    performanceDiagnostics.readMergeMilliseconds = RepositoryPerformanceClock.elapsedMilliseconds(since: readStart)
                    try measureCommit { try repository.mergeSyncData(merged) }
                    if writeBack {
                        let encodeStart = RepositoryPerformanceClock.now()
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys]
                        encoder.dateEncodingStrategy = .iso8601
                        let data = try encoder.encode(repository.syncData())
                        performanceDiagnostics.encodeMilliseconds = RepositoryPerformanceClock.elapsedMilliseconds(since: encodeStart)
                        performanceDiagnostics.payloadBytes = data.count
                        try measureWrite { try (write ?? { try writeAtomically($0, to: $1) })(data, coordinatedURL) }
                        // A read-only import never resolves conflicts. The shared
                        // merged replacement must be durable before resolution.
                        for version in versions { version.isResolved = true }
                    }
                } catch { operationError = error }
            }
            try coordinate(fileURL, writing: writeBack, using: coordination, accessor: operation)
            if let operationError { throw operationError }
            }
        } catch {
            lastSyncStatus = .failed
            throw error
        }
    }

    /// Applies an explicit user decision to a pending conflict. Candidate
    /// files are intentionally never deleted; only the primary sync file is
    /// replaced with the selected, credential-free projection.
    @MainActor
    public static func resolve(repository: any LocalRepository, report: SyncConflictReport,
                               decision: SyncConflictDecision) throws -> SyncResolutionResult {
        try resolve(repository: repository, report: report, decision: decision, coordination: nil)
    }

    @MainActor
    static func resolve(
        repository: any LocalRepository,
        report: SyncConflictReport,
        decision: SyncConflictDecision,
        coordination: Coordination?,
        write: ((Data, URL) throws -> Void)? = nil
    ) throws -> SyncResolutionResult {
        let started = RepositoryPerformanceClock.now()
        performanceDiagnostics = SyncPerformanceDiagnostics()
        lastConflictReport = report
        lastSyncStatus = .failed
        defer {
            performanceDiagnostics.totalMilliseconds = RepositoryPerformanceClock.elapsedMilliseconds(since: started)
            performanceDiagnostics.succeeded = lastSyncStatus == .merged
        }
        let resolution = try SyncConflictService().resolve(report: report, decision: decision)
        guard let primary = report.remoteCandidates.first(where: { candidate in
            if case .remote = candidate.source { return true }
            return false
        })?.fileURL else {
            throw SyncConflictError.remoteCandidateUnavailable
        }

        let encodeStart = RepositoryPerformanceClock.now()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(resolution.data)
        performanceDiagnostics.encodeMilliseconds = RepositoryPerformanceClock.elapsedMilliseconds(since: encodeStart)
        performanceDiagnostics.payloadBytes = data.count
        try withSecurityScopedAccess(primary.deletingLastPathComponent()) {
            var operationError: Error?
            let operation: (URL) -> Void = { coordinatedURL in
                do {
                    try measureCommit { try repository.mergeSyncData(resolution.data) }
                    try measureWrite { try (write ?? { try writeAtomically($0, to: $1) })(data, coordinatedURL) }
                } catch {
                    operationError = error
                }
            }
            try coordinate(primary, writing: true, using: coordination, accessor: operation)
            if let operationError { throw operationError }
        }
        lastConflictReport = nil
        lastSyncStatus = .merged
        return resolution
    }

    @MainActor private static func measureCommit(_ body: () throws -> Void) rethrows {
        let start = RepositoryPerformanceClock.now()
        defer { performanceDiagnostics.localCommitMilliseconds += RepositoryPerformanceClock.elapsedMilliseconds(since: start) }
        try body()
    }

    @MainActor private static func measureWrite(_ body: () throws -> Void) rethrows {
        let start = RepositoryPerformanceClock.now()
        defer { performanceDiagnostics.writeMilliseconds += RepositoryPerformanceClock.elapsedMilliseconds(since: start) }
        try body()
    }

    private static func repositoryURL(_ repository: any LocalRepository) -> URL {
        // Conflict reports need a stable local identity, not a credential. The
        // repository protocol intentionally does not expose its file URL, so a
        // process-local synthetic URL is sufficient for the UI contract.
        URL(fileURLWithPath: "relay-local-repository")
    }

    static func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".relay-sync-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    static func readPayloadIfPresent(at url: URL) throws -> RelaySyncData? {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        if values.ubiquitousItemDownloadingStatus == .notDownloaded {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw FileSyncError.downloadPending
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
            if data.isEmpty { return nil }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Some non-ubiquitous URLs return empty resource values even when
            // absent. Only ENOENT from the actual read means a new sync file.
            return nil
        }
        let payload = try decode(data)
        guard payload.schemaVersion == RelaySyncData.currentSchemaVersion,
              payload.settings.schemaVersion == RelaySettings.currentSchemaVersion else {
            throw FileSyncError.unsupportedVersion
        }
        return payload
    }

    static func withSecurityScopedAccess<T>(_ directory: URL, _ body: () throws -> T) rethrows -> T {
        let didStart = directory.startAccessingSecurityScopedResource()
        defer {
            if didStart { directory.stopAccessingSecurityScopedResource() }
        }
        return try body()
    }

    private static func decode(_ data: Data) throws -> RelaySyncData {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RelaySyncData.self, from: data)
    }

}

public enum FileSyncError: LocalizedError, Sendable {
    case invalidDirectory
    case coordinationFailed
    case dataChanged
    case unreadableConflict
    case unsupportedVersion
    case downloadPending

    public var errorDescription: String? {
        switch self {
        case .dataChanged: return "同步期间数据持续变化，请稍后重试。已保留本机数据和远端版本。"
        case .coordinationFailed: return "文件协调失败，请稍后重试。本机数据仍然可用。"
        case .invalidDirectory:
            return "同步目录不可用，请重新选择文件夹。本机数据仍然可用。"
        case .unreadableConflict:
            return "同步冲突文件无法读取，已保留原文件，未覆盖云端数据。"
        case .unsupportedVersion:
            return "同步文件版本不受支持，已停止覆盖，请更新 Relay。"
        case .downloadPending:
            return "正在等待 iCloud 下载同步文件，本机数据仍然可用。"
        }
    }
}

/// Last attempt only; never persisted, synced or exported automatically.
public struct SyncPerformanceDiagnostics: Sendable, Equatable {
    public internal(set) var totalMilliseconds: Double = 0
    public internal(set) var coordinationMilliseconds: Double = 0
    public internal(set) var readMergeMilliseconds: Double = 0
    public internal(set) var localCommitMilliseconds: Double = 0
    public internal(set) var encodeMilliseconds: Double = 0
    public internal(set) var writeMilliseconds: Double = 0
    public internal(set) var payloadBytes = 0
    public internal(set) var succeeded = false
    public init() {}
}
