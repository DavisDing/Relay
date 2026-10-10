import Foundation
import Darwin

public enum BackupDirectoryError: Error, LocalizedError, Sendable, Equatable {
    case invalidDirectory
    case bookmarkUnavailable
    case credentialDirectory
    case migrationConflict
    case sourceChanged
    case notWritable
    public var errorDescription: String? {
        switch self {
        case .invalidDirectory: return "备份位置必须是现有文件夹，且不能包含符号链接。"
        case .bookmarkUnavailable: return "备份目录授权已失效，请重新选择目录；未改用默认目录。"
        case .credentialDirectory: return "不能将凭据存储目录或其上级目录选为备份位置。"
        case .migrationConflict: return "新目录已有同名但内容不同的备份，未切换目录。"
        case .sourceChanged: return "旧备份在搬移期间发生变化，未删除原文件，请重试。"
        case .notWritable: return "无法在所选目录写入备份，请检查权限。"
        }
    }
}

/// Injectable only to keep bookmark persistence checks independent of native
/// picker access. Production always uses a security-scoped bookmark.
struct BackupDirectoryBookmarkCodec {
    let encode: (URL) throws -> Data
    let decode: (Data) throws -> URL
    static let securityScoped = BackupDirectoryBookmarkCodec(
        encode: { try $0.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: [.isDirectoryKey], relativeTo: nil) },
        decode: { data in
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw BackupDirectoryError.bookmarkUnavailable }
            return url
        }
    )
}

struct BackupMigrationIO {
    var read: (URL) throws -> Data = { try Data(contentsOf: $0) }
    var write: (Data, URL) throws -> Void = { try PrivateFileWriter.write($0, to: $1) }
    var remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
}

/// Credentials are never read. The selected parent is locally bookmarked and
/// each operation acquires its scope. Only our dedicated child receives chmod.
public actor LocalBackupService {
    public static let retentionCount = 5
    public static let shared = LocalBackupService()
    static let bookmarkPreferenceKey = "relay.localBackupDirectoryBookmark"
    private static let pathPreferenceKey = "relay.localBackupDirectoryPath"
    public private(set) var directoryURL: URL
    private let defaultDirectoryURL: URL
    private let credentialDirectoryURL: URL
    private let preferences: UserDefaults?
    private let codec: BackupDirectoryBookmarkCodec
    private let migrationIO: BackupMigrationIO

    public init(directoryURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Relay", isDirectory: true)
        let fallback = Self.canonicalFallback(directoryURL ?? support.appendingPathComponent("Backups", isDirectory: true))
        defaultDirectoryURL = fallback
        self.directoryURL = fallback
        credentialDirectoryURL = support.deletingLastPathComponent().appendingPathComponent("cloud.dinghao.relay", isDirectory: true)
        preferences = directoryURL == nil ? .standard : nil
        codec = .securityScoped
        migrationIO = BackupMigrationIO()
    }

    init(directoryURL: URL, preferences: UserDefaults, codec: BackupDirectoryBookmarkCodec, credentialDirectoryURL: URL, migrationIO: BackupMigrationIO = BackupMigrationIO()) {
        self.defaultDirectoryURL = Self.canonicalFallback(directoryURL)
        self.directoryURL = Self.canonicalFallback(directoryURL)
        self.preferences = preferences
        self.codec = codec
        self.migrationIO = migrationIO
        self.credentialDirectoryURL = credentialDirectoryURL
    }

    /// A missing or invalid stored bookmark is an error, never a fallback.
    public func currentDirectoryURL() throws -> URL { try withDirectory { $0 } }

    @discardableResult
    public func selectDirectory(_ parent: URL) throws -> String? {
        let started = parent.startAccessingSecurityScopedResource()
        defer { if started { parent.stopAccessingSecurityScopedResource() } }
        try validateParent(parent)
        let child = parent.appendingPathComponent("RelayBackups", isDirectory: true)
        try validateOwnedChild(child)
        let bookmark: Data
        do { bookmark = try codec.encode(parent) }
        catch { throw BackupDirectoryError.bookmarkUnavailable }
        // Resolve and inspect before persisting, including fixtures which model
        // stale/invalid bookmarks without requiring a WindowServer.
        let resolved: URL
        do { resolved = try codec.decode(bookmark) }
        catch { throw BackupDirectoryError.bookmarkUnavailable }
        guard Self.canonicalFallback(resolved).path == Self.canonicalFallback(parent).path else { throw BackupDirectoryError.bookmarkUnavailable }
        try validateParent(resolved)
        try probeWritable(child)
        // Selecting the same saved parent renews authorization without moving
        // anything; this also recovers a stale bookmark via the native picker.
        if let saved = preferences?.string(forKey: Self.pathPreferenceKey),
           Self.canonicalFallback(URL(fileURLWithPath: saved)).path == Self.canonicalFallback(parent).path {
            preferences?.set(bookmark, forKey: Self.bookmarkPreferenceKey)
            directoryURL = child
            return nil
        }
        return try withDirectory { source in
            try migrate(from: source, to: child) {
                if let preferences {
                    preferences.set(bookmark, forKey: Self.bookmarkPreferenceKey)
                    preferences.set(parent.path, forKey: Self.pathPreferenceKey)
                } else { fixtureParent = parent }
                directoryURL = child
            }
        }
    }

    @discardableResult
    public func resetDirectory() throws -> String? {
        try validateOwnedChild(defaultDirectoryURL)
        try probeWritable(defaultDirectoryURL)
        return try withDirectory { source in
            try migrate(from: source, to: defaultDirectoryURL) {
                preferences?.removeObject(forKey: Self.bookmarkPreferenceKey)
                preferences?.removeObject(forKey: Self.pathPreferenceKey)
                fixtureParent = nil
                directoryURL = defaultDirectoryURL
            }
        }
    }

    /// Copy and verify the complete owned set before changing the preference.
    /// Cleanup happens only after verified copies are the active recovery point.
    private func migrate(from source: URL, to target: URL, commit: () -> Void) throws -> String? {
        if Self.canonicalFallback(source).path == Self.canonicalFallback(target).path { commit(); return nil }
        let files = try backupFiles(source)
        var copied: [URL] = []
        var originals: [(URL, Data)] = []
        do {
            for file in files {
                _ = try boundedRead(file.url)
                let bytes = try migrationIO.read(file.url)
                guard bytes.count <= DataTransferService.maximumFileBytes else { throw DataTransferError.tooLarge }
                let destination = target.appendingPathComponent(file.url.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try boundedRead(destination)
                    guard try migrationIO.read(destination) == bytes else { throw BackupDirectoryError.migrationConflict }
                } else {
                    copied.append(destination)
                    try migrationIO.write(bytes, destination)
                    try FileManager.default.setAttributes([.modificationDate: file.date], ofItemAtPath: destination.path)
                }
                guard try migrationIO.read(destination) == bytes else { throw BackupDirectoryError.sourceChanged }
                originals.append((file.url, bytes))
            }
            guard Set(try backupFiles(source).map { $0.url.lastPathComponent }) == Set(files.map { $0.url.lastPathComponent }) else {
                throw BackupDirectoryError.sourceChanged
            }
            for (original, bytes) in originals {
                guard try migrationIO.read(original) == bytes else { throw BackupDirectoryError.sourceChanged }
            }
        } catch {
            for destination in copied { try? migrationIO.remove(destination) }
            throw error
        }
        commit()
        var remaining = 0
        for (original, bytes) in originals {
            do {
                let destination = target.appendingPathComponent(original.lastPathComponent)
                guard try migrationIO.read(original) == bytes,
                      try boundedRead(destination) == bytes else { remaining += 1; continue }
                try migrationIO.remove(original)
            } catch { remaining += 1 }
        }
        return remaining == 0 ? nil : "备份已搬到新目录；旧目录有 \(remaining) 个文件未能清理，原件仍保留。"
    }

    private var fixtureParent: URL?

    @discardableResult
    public func create(_ data: RelaySyncData, at date: Date = Date()) throws -> LocalBackupEntry {
        try withDirectory { directory in try createInDirectory(data, at: date, directory: directory) }
    }

    @discardableResult
    public func createIfNeeded(_ data: RelaySyncData, at date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) throws -> LocalBackupEntry? {
        try withDirectory { directory in
            if try listInDirectory(directory).contains(where: { calendar.isDate($0.createdAt, inSameDayAs: date) }) { return nil }
            return try createInDirectory(data, at: date, directory: directory)
        }
    }

    public func list() throws -> [LocalBackupEntry] { try withDirectory { try listInDirectory($0) } }

    public func preview(_ entry: LocalBackupEntry) throws -> LocalBackupPreview {
        try withDirectory { directory in
            let path = entry.fileURL.standardizedFileURL
            guard path.deletingLastPathComponent() == directory.standardizedFileURL, backupID(path) == entry.id else { throw DataTransferError.backupUnavailable }
            let data = try DataTransferService.decodeBackup(boundedRead(path))
            return LocalBackupPreview(entry: entry, data: data)
        }
    }

    private func withDirectory<T>(_ action: (URL) throws -> T) throws -> T {
        let parent: URL?
        if let stored = preferences?.object(forKey: Self.bookmarkPreferenceKey) {
            guard let bytes = stored as? Data else { throw BackupDirectoryError.bookmarkUnavailable }
            do { parent = try codec.decode(bytes) }
            catch { throw BackupDirectoryError.bookmarkUnavailable }
        } else {
            parent = fixtureParent
        }
        if let parent {
            let started = parent.startAccessingSecurityScopedResource()
            defer { if started { parent.stopAccessingSecurityScopedResource() } }
            try validateParent(parent)
            let child = parent.appendingPathComponent("RelayBackups", isDirectory: true)
            try validateOwnedChild(child)
            directoryURL = child
            return try action(child)
        }
        // A path hint with a missing bookmark means lost authorization.
        if preferences?.object(forKey: Self.pathPreferenceKey) != nil { throw BackupDirectoryError.bookmarkUnavailable }
        try validateOwnedChild(defaultDirectoryURL)
        directoryURL = defaultDirectoryURL
        return try action(defaultDirectoryURL)
    }

    private func validateParent(_ parent: URL) throws {
        guard parent.isFileURL else { throw BackupDirectoryError.invalidDirectory }
        try rejectSymlinkComponents(parent)
        let attrs = try FileManager.default.attributesOfItem(atPath: parent.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw BackupDirectoryError.invalidDirectory }
        let selected = parent.standardizedFileURL.resolvingSymlinksInPath().path
        let credential = credentialDirectoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        // Choosing an ancestor of the credential dir could expose its files to
        // backups; descendants are safe only when dedicated to backup storage.
        guard selected != credential, !selected.hasPrefix(credential + "/"), !credential.hasPrefix(selected.hasSuffix("/") ? selected : selected + "/") else {
            throw BackupDirectoryError.credentialDirectory
        }
    }

    private func validateOwnedChild(_ child: URL) throws {
        guard child.isFileURL else { throw BackupDirectoryError.invalidDirectory }
        try rejectSymlinkComponents(child)
        if FileManager.default.fileExists(atPath: child.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: child.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw BackupDirectoryError.invalidDirectory }
        }
    }

    /// Foundation leaves aliases in an absent descendant unresolved. Resolve
    /// the closest real ancestor, then append the not-yet-created components.
    /// Only the internal/injected fallback uses this normalization; selected
    /// user parents still reject symbolic links other than fixed system aliases.
    private static func canonicalFallback(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while ancestor.path != "/" && !FileManager.default.fileExists(atPath: ancestor.path) {
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        // URL.resolvingSymlinksInPath / standardizedFileURL may shorten
        // /private/var back to /var on macOS. POSIX realpath keeps the actual
        // directory identity, including when children do not exist yet.
        let resolvedPath: String
        if let pointer = realpath(ancestor.path, nil) {
            resolvedPath = String(cString: pointer)
            free(pointer)
        } else {
            resolvedPath = ancestor.path
        }
        var result = URL(fileURLWithPath: resolvedPath, isDirectory: true)
        for component in missing.reversed() { result.appendPathComponent(component, isDirectory: true) }
        return result
    }

    private func rejectSymlinkComponents(_ url: URL) throws {
        // Do not standardize here: Foundation shortens canonical /private/var
        // to its /var alias, introducing a symlink which wasn't in this path.
        var candidate = url
        while candidate.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                // macOS exposes these system directories through fixed aliases.
                // Accept only their exact expected targets, never a user alias
                // or a replacement link pointing at a credential directory.
                let expected = ["/var": "/private/var", "/tmp": "/private/tmp", "/etc": "/private/etc"][candidate.path]
                let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)
                guard let expected, let destination else { throw BackupDirectoryError.invalidDirectory }
                let absolute = destination.hasPrefix("/") ? destination : candidate.deletingLastPathComponent().appendingPathComponent(destination).path
                guard absolute == expected else { throw BackupDirectoryError.invalidDirectory }
            }
            candidate.deleteLastPathComponent()
        }
    }

    private func probeWritable(_ directory: URL) throws {
        let probe = directory.appendingPathComponent(".relay-backup-probe-\(UUID().uuidString)")
        do {
            try PrivateFileWriter.write(Data(), to: probe)
            try FileManager.default.removeItem(at: probe)
        } catch { throw BackupDirectoryError.notWritable }
    }

    private func createInDirectory(_ data: RelaySyncData, at date: Date, directory: URL) throws -> LocalBackupEntry {
        let id = UUID()
        let safe = RelaySyncData(exportedAt: date, accounts: data.accounts, snapshots: data.snapshots, dailyUsage: data.dailyUsage,
                                 settings: data.settings, settingsUpdatedAt: data.settingsUpdatedAt, deletedAccountIDs: data.deletedAccountIDs)
        let bytes = try DataTransferService.exportBackup(safe)
        let url = directory.appendingPathComponent("relay-backup-\(Int(date.timeIntervalSince1970))-\(id.uuidString).json")
        try PrivateFileWriter.write(bytes, to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        for old in try backupFiles(directory).dropFirst(Self.retentionCount) { try FileManager.default.removeItem(at: old.url) }
        return LocalBackupEntry(id: id, createdAt: date, fileURL: url, accountCount: safe.accounts.count, historyCount: safe.dailyUsage.count)
    }

    private func listInDirectory(_ directory: URL) throws -> [LocalBackupEntry] {
        try backupFiles(directory).compactMap { file in
            guard let bytes = try? boundedRead(file.url), let data = try? DataTransferService.decodeBackup(bytes), let id = backupID(file.url) else { return nil }
            return LocalBackupEntry(id: id, createdAt: file.date, fileURL: file.url, accountCount: data.accounts.count, historyCount: data.dailyUsage.count)
        }
    }

    private func boundedRead(_ url: URL) throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else { throw DataTransferError.backupUnavailable }
        guard let size = attrs[.size] as? NSNumber, size.intValue <= DataTransferService.maximumFileBytes else { throw DataTransferError.tooLarge }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= DataTransferService.maximumFileBytes else { throw DataTransferError.tooLarge }
        return bytes
    }

    private func backupID(_ url: URL) -> UUID? {
        let name = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == "json", name.hasPrefix("relay-backup-"), name.count >= 36 else { return nil }
        return UUID(uuidString: String(name.suffix(36)))
    }

    private func backupFiles(_ directory: URL) throws -> [(url: URL, date: Date)] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .compactMap { url in
                guard backupID(url) != nil else { return nil }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
                return (url: url, date: (attributes[.modificationDate] as? Date) ?? .distantPast)
            }.sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.url.lastPathComponent > $1.url.lastPathComponent
            }
    }
}
