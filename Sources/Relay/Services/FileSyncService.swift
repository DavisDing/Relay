import Foundation

/// Best-effort iCloud Drive ordinary-file sync for non-secret Relay data.
/// Credentials are structurally absent from RelaySyncData and are never written here.
/// The selected directory is kept as a security-scoped bookmark, not reconstructed
/// from a localized iCloud Drive path.
public enum FileSyncService {
    public static let fileName = "relay-sync-v1.json"
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
        try withSecurityScopedAccess(directory) {
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw FileSyncError.invalidDirectory
            }
            let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
            var coordinationError: NSError?
            var operationError: Error?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            let operation: (URL) -> Void = { coordinatedURL in
                do {
                    let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: coordinatedURL) ?? []
                    var merged = try repository.syncData()
                    if let primary = try readPayloadIfPresent(at: coordinatedURL) {
                        merged = try SyncMerge.merge(merged, primary)
                    }
                    // Do not discard an unreadable or unknown-version conflict.
                    // Validate ALL versions before changing the local repository.
                    for version in versions {
                        guard let payload = try readPayloadIfPresent(at: version.url) else {
                            throw FileSyncError.unreadableConflict
                        }
                        merged = try SyncMerge.merge(merged, payload)
                    }
                    try repository.mergeSyncData(merged)
                    if writeBack {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys]
                        encoder.dateEncodingStrategy = .iso8601
                        let data = try encoder.encode(repository.syncData())
                        try data.write(to: coordinatedURL, options: .atomic)
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
            if let operationError { throw operationError }
            if let coordinationError { throw coordinationError }
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
