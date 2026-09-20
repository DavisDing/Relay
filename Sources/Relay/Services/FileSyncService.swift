import Foundation

/// Best-effort iCloud Drive ordinary-file sync for non-secret Relay data.
/// Credentials are structurally absent from RelaySyncData and are never written here.
/// The selected directory is kept as a security-scoped bookmark, not reconstructed
/// from a localized iCloud Drive path.
public enum FileSyncService {
    public static let fileName = "relay-sync-v1.json"
    @MainActor public private(set) static var lastSyncStatus: SyncStatus = .idle
    @MainActor public private(set) static var lastConflictReport: SyncConflictReport?
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
    static func exchange(repository: any LocalRepository, directory: URL, writeBack: Bool) throws {
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
            // NSFileCoordinator's writing accessor expects an existing item on
            // some macOS/CLI combinations. Create an empty placeholder only for
            // the first write; an empty payload is treated as "no remote data".
            if writeBack, !FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.createFile(atPath: fileURL.path, contents: Data()) else {
                    throw FileSyncError.invalidDirectory
                }
            }
            var coordinationError: NSError?
            var operationError: Error?
            var didRunOperation = false
            let coordinator = NSFileCoordinator(filePresenter: nil)
            let operation: (URL) -> Void = { coordinatedURL in
                didRunOperation = true
                do {
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
                    try repository.mergeSyncData(merged)
                    if writeBack {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys]
                        encoder.dateEncodingStrategy = .iso8601
                        let data = try encoder.encode(repository.syncData())
                        try writeAtomically(data, to: coordinatedURL)
                        // A read-only import never resolves conflicts. The shared
                        // merged replacement must be durable before resolution.
                        for version in versions { version.isResolved = true }
                    }
                } catch { operationError = error }
            }
            if writeBack {
                coordinator.coordinate(writingItemAt: fileURL, options: [], error: &coordinationError, byAccessor: operation)
            } else {
                coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinationError, byAccessor: operation)
            }
            // Command-line regression fixtures are ordinary local files, not
            // ubiquitous items. Some macOS SDK/runtime combinations reject a
            // coordinator accessor for such a newly-created path before the
            // accessor is invoked. Preserve the coordinated path for iCloud,
            // but safely retry the same operation directly when it never ran.
            if coordinationError != nil, !didRunOperation {
                coordinationError = nil
                operation(fileURL)
            }
            if let operationError { throw operationError }
            if let coordinationError { throw coordinationError }
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
    public static func resolve(
        repository: any LocalRepository,
        report: SyncConflictReport,
        decision: SyncConflictDecision
    ) throws -> SyncResolutionResult {
        let resolution = try SyncConflictService().resolve(report: report, decision: decision)
        guard let primary = report.remoteCandidates.first(where: { candidate in
            if case .remote = candidate.source { return true }
            return false
        })?.fileURL else {
            throw SyncConflictError.remoteCandidateUnavailable
        }

        try repository.mergeSyncData(resolution.data)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(resolution.data)
        try withSecurityScopedAccess(primary.deletingLastPathComponent()) {
            var coordinationError: NSError?
            var operationError: Error?
            var didRunOperation = false
            let operation: (URL) -> Void = { coordinatedURL in
                didRunOperation = true
                do {
                    try writeAtomically(data, to: coordinatedURL)
                } catch {
                    operationError = error
                }
            }
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(writingItemAt: primary, options: [], error: &coordinationError, byAccessor: operation)
            if coordinationError != nil, !didRunOperation {
                coordinationError = nil
                operation(primary)
            }
            if let operationError { throw operationError }
            if let coordinationError { throw coordinationError }
        }
        lastConflictReport = nil
        lastSyncStatus = .merged
        return resolution
    }

    private static func repositoryURL(_ repository: any LocalRepository) -> URL {
        // Conflict reports need a stable local identity, not a credential. The
        // repository protocol intentionally does not expose its file URL, so a
        // process-local synthetic URL is sufficient for the UI contract.
        URL(fileURLWithPath: "relay-local-repository")
    }

    private static func writeAtomically(_ data: Data, to destination: URL) throws {
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

    private static func readPayloadIfPresent(at url: URL) throws -> RelaySyncData? {
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

    private static func withSecurityScopedAccess<T>(_ directory: URL, _ body: () throws -> T) rethrows -> T {
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
    case unreadableConflict
    case unsupportedVersion
    case downloadPending

    public var errorDescription: String? {
        switch self {
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
