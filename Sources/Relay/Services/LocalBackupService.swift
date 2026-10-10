import Foundation

/// An isolated directory holds only sanitized business data. The credential
/// store is never opened by this service.
public actor LocalBackupService {
    public static let retentionCount = 5
    /// UI actions, automatic snapshots and transfer recovery points share one
    /// serial executor so retention cannot race within the application.
    public static let shared = LocalBackupService()
    public let directoryURL: URL

    public init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relay/Backups", isDirectory: true)
    }

    @discardableResult
    public func create(_ data: RelaySyncData, at date: Date = Date()) throws -> LocalBackupEntry {
        let id = UUID()
        let safe = RelaySyncData(exportedAt: date, accounts: data.accounts, snapshots: data.snapshots, dailyUsage: data.dailyUsage,
                                 settings: data.settings, settingsUpdatedAt: data.settingsUpdatedAt,
                                 deletedAccountIDs: data.deletedAccountIDs)
        let bytes = try DataTransferService.exportBackup(safe)
        let filename = "relay-backup-\(Int(date.timeIntervalSince1970))-\(id.uuidString).json"
        let fileURL = directoryURL.appendingPathComponent(filename)
        try PrivateFileWriter.write(bytes, to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
        // Only files owned by this backup naming contract can be pruned. An
        // unreadable generation still counts toward the bounded retention.
        let files = try backupFiles()
        for old in files.dropFirst(Self.retentionCount) {
            try FileManager.default.removeItem(at: old.url)
        }
        return LocalBackupEntry(id: id, createdAt: date, fileURL: fileURL,
                                accountCount: safe.accounts.count, historyCount: safe.dailyUsage.count)
    }

    /// Called by the application lifecycle while it is running. A valid manual
    /// or recovery backup made today also satisfies the daily automatic backup.
    /// Checking and creating have no suspension point on this serial executor.
    @discardableResult
    public func createIfNeeded(
        _ data: RelaySyncData,
        at date: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> LocalBackupEntry? {
        if try list().contains(where: { calendar.isDate($0.createdAt, inSameDayAs: date) }) { return nil }
        return try create(data, at: date)
    }

    public func list() throws -> [LocalBackupEntry] {
        try backupFiles().compactMap { file in
            guard let bytes = try? boundedRead(file.url), let data = try? DataTransferService.decodeBackup(bytes),
                  let id = backupID(file.url) else { return nil }
            return LocalBackupEntry(id: id, createdAt: file.date, fileURL: file.url,
                                    accountCount: data.accounts.count, historyCount: data.dailyUsage.count)
        }
    }

    public func preview(_ entry: LocalBackupEntry) throws -> LocalBackupPreview {
        let root = directoryURL.standardizedFileURL
        let path = entry.fileURL.standardizedFileURL
        guard path.deletingLastPathComponent() == root, backupID(path) == entry.id else { throw DataTransferError.backupUnavailable }
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw DataTransferError.backupUnavailable }
        let data = try DataTransferService.decodeBackup(boundedRead(path))
        return LocalBackupPreview(entry: entry, data: data)
    }

    private func boundedRead(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw DataTransferError.backupUnavailable }
        guard let size = attributes[.size] as? NSNumber, size.intValue <= DataTransferService.maximumFileBytes else { throw DataTransferError.tooLarge }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= DataTransferService.maximumFileBytes else { throw DataTransferError.tooLarge }
        return bytes
    }

    private func backupID(_ url: URL) -> UUID? {
        let filename = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == "json", filename.hasPrefix("relay-backup-"), filename.count >= 36 else { return nil }
        return UUID(uuidString: String(filename.suffix(36)))
    }

    private func backupFiles() throws -> [(url: URL, date: Date)] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
            .compactMap { url in
                guard backupID(url) != nil else { return nil }
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true else { return nil }
                return (url: url, date: values.contentModificationDate ?? .distantPast)
            }.sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.url.lastPathComponent > $1.url.lastPathComponent
            }
    }
}
