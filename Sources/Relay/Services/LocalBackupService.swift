import Foundation
import Darwin
import CryptoKit

public enum BackupDirectoryError: Error, LocalizedError, Sendable, Equatable {
    case invalidDirectory
    case bookmarkUnavailable
    case credentialDirectory
    case migrationConflict
    case sourceChanged
    case migrationPending
    case notWritable
    public var errorDescription: String? {
        switch self {
        case .invalidDirectory: return "备份位置必须是现有文件夹，且不能包含符号链接。"
        case .bookmarkUnavailable: return "备份目录授权已失效，请重新选择目录；未改用默认目录。"
        case .credentialDirectory: return "不能将凭据存储目录或其上级目录选为备份位置。"
        case .migrationConflict: return "新目录已有同名但内容不同的备份，未切换目录。"
        case .sourceChanged: return "旧备份在搬移期间发生变化，未删除原文件，请重试。"
        case .migrationPending: return "有未完成的备份搬移，请先重试处理或重新授权搬移目录。"
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
    private static let selectionPreferenceKey = "relay.localBackupSelection"
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

    private var selectionURL: URL { defaultDirectoryURL.appendingPathComponent(".relay-backup-selection.json") }
    private struct DirectorySelection: Codable { let bookmark: Data?; let path: String? }
    private func selection() throws -> DirectorySelection {
        if FileManager.default.fileExists(atPath: selectionURL.path) {
            let bytes = try boundedRead(selectionURL)
            do { return try JSONDecoder().decode(DirectorySelection.self, from: bytes) }
            catch { throw BackupDirectoryError.bookmarkUnavailable }
        }
        if let bytes = preferences?.data(forKey: Self.selectionPreferenceKey) {
            do { return try JSONDecoder().decode(DirectorySelection.self, from: bytes) }
            catch { throw BackupDirectoryError.bookmarkUnavailable }
        }
        let stored = preferences?.object(forKey: Self.bookmarkPreferenceKey)
        if stored != nil && !(stored is Data) { throw BackupDirectoryError.bookmarkUnavailable }
        return DirectorySelection(bookmark: stored as? Data, path: preferences?.string(forKey: Self.pathPreferenceKey))
    }
    private func persistSelection(bookmark: Data?, path: String?) throws {
        // The owner-private atomic file is the durable commit marker. Defaults
        // are compatibility hints and cannot be trusted after a forced exit.
        let bytes = try JSONEncoder().encode(DirectorySelection(bookmark: bookmark, path: path))
        try PrivateFileWriter.write(bytes, to: selectionURL)
        guard let preferences else { return }
        preferences.set(bytes, forKey: Self.selectionPreferenceKey)
        if let bookmark { preferences.set(bookmark, forKey: Self.bookmarkPreferenceKey) }
        else { preferences.removeObject(forKey: Self.bookmarkPreferenceKey) }
        if let path { preferences.set(path, forKey: Self.pathPreferenceKey) }
        else { preferences.removeObject(forKey: Self.pathPreferenceKey) }
    }

    /// A missing or invalid stored bookmark is an error, never a fallback.
    public func currentDirectoryURL() throws -> URL { try withDirectory { $0 } }

    public func renewDirectoryAuthorization(_ parent: URL) throws {
        guard let saved = try selection().path,
              Self.canonicalFallback(URL(fileURLWithPath: saved)) == Self.canonicalFallback(parent) else { throw BackupDirectoryError.bookmarkUnavailable }
        let started = parent.startAccessingSecurityScopedResource()
        defer { if started { parent.stopAccessingSecurityScopedResource() } }
        try validateParent(parent)
        let bookmark = try codec.encode(parent)
        guard Self.canonicalFallback(try codec.decode(bookmark)) == Self.canonicalFallback(parent) else { throw BackupDirectoryError.bookmarkUnavailable }
        try persistSelection(bookmark: bookmark, path: parent.path)
    }

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
        if let saved = try selection().path,
           Self.canonicalFallback(URL(fileURLWithPath: saved)).path == Self.canonicalFallback(parent).path {
            try persistSelection(bookmark: bookmark, path: parent.path)
            directoryURL = child
            return nil
        }
        return try withDirectory { source in
            try migrate(from: source, to: child) {
                try persistSelection(bookmark: bookmark, path: parent.path)
                if preferences == nil { fixtureParent = parent }
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
                try persistSelection(bookmark: nil, path: nil)
                fixtureParent = nil
                directoryURL = defaultDirectoryURL
            }
        }
    }

    private struct Migration: Codable {
        struct File: Codable { let name: String; let digest: String; let createdDestination: Bool }
        var source: URL
        var target: URL
        var sourceBookmark: Data?
        var targetBookmark: Data?
        var phase: String
        var files: [File]
    }
    private var journalURL: URL { defaultDirectoryURL.appendingPathComponent(".relay-backup-migration.json") }
    private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func readMigration() throws -> Migration? {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
        let bytes = try boundedRead(journalURL)
        return try JSONDecoder().decode(Migration.self, from: bytes)
    }
    private func saveMigration(_ migration: Migration) throws {
        try PrivateFileWriter.write(JSONEncoder().encode(migration), to: journalURL)
    }
    public func hasPendingMigration() -> Bool { FileManager.default.fileExists(atPath: journalURL.path) }

    /// Renew the exact source or destination grant without starting another migration.
    public func authorizePendingMigration(_ parent: URL) throws {
        guard var migration = try readMigration() else { return }
        let started = parent.startAccessingSecurityScopedResource()
        defer { if started { parent.stopAccessingSecurityScopedResource() } }
        try validateParent(parent)
        let child = Self.canonicalFallback(parent.appendingPathComponent("RelayBackups"))
        let bookmark = try codec.encode(parent)
        if child == Self.canonicalFallback(migration.source) { migration.sourceBookmark = bookmark }
        else if child == Self.canonicalFallback(migration.target) { migration.targetBookmark = bookmark }
        else { throw BackupDirectoryError.invalidDirectory }
        try saveMigration(migration)
        if let saved = try selection().path,
           Self.canonicalFallback(URL(fileURLWithPath: saved)) == Self.canonicalFallback(parent) {
            try persistSelection(bookmark: bookmark, path: parent.path)
        }
    }

    public func retryPendingMigration() throws -> String? {
        guard let migration = try readMigration() else { return nil }
        let sourceParent = try migration.sourceBookmark.map { try codec.decode($0) }
        let targetParent = try migration.targetBookmark.map { try codec.decode($0) }
        let grants = [sourceParent, targetParent].compactMap { $0 }
        let started = grants.map { $0.startAccessingSecurityScopedResource() }
        defer { for (parent, didStart) in zip(grants, started) where didStart { parent.stopAccessingSecurityScopedResource() } }
        for parent in grants { try validateParent(parent) }
        for (directory, parent) in [(migration.source, sourceParent), (migration.target, targetParent)] {
            if let parent {
                guard Self.canonicalFallback(parent.appendingPathComponent("RelayBackups")) == Self.canonicalFallback(directory) else { throw BackupDirectoryError.bookmarkUnavailable }
            } else { guard Self.canonicalFallback(directory) == defaultDirectoryURL else { throw BackupDirectoryError.bookmarkUnavailable } }
            try validateOwnedChild(directory)
        }
        let active = try currentDirectoryURL()
        let committed = Self.canonicalFallback(active) == Self.canonicalFallback(migration.target)
        guard committed || Self.canonicalFallback(active) == Self.canonicalFallback(migration.source) else { throw BackupDirectoryError.sourceChanged }
        var remaining = 0
        for file in migration.files {
            let original = migration.source.appendingPathComponent(file.name)
            let destination = migration.target.appendingPathComponent(file.name)
            guard backupID(original) != nil, original.lastPathComponent == file.name,
                  !file.name.contains("/"), !file.name.contains("..") else { throw BackupDirectoryError.invalidDirectory }
            do {
                if committed {
                    guard FileManager.default.fileExists(atPath: original.path) else { continue }
                    guard digest(try boundedRead(original)) == file.digest,
                          digest(try boundedRead(destination)) == file.digest else { remaining += 1; continue }
                    try migrationIO.remove(original)
                } else if file.createdDestination && FileManager.default.fileExists(atPath: destination.path) {
                    // Rollback only verified copies, while the original still exists.
                    guard digest(try boundedRead(original)) == file.digest,
                          digest(try boundedRead(destination)) == file.digest else { remaining += 1; continue }
                    try migrationIO.remove(destination)
                }
            } catch { remaining += 1 }
        }
        if remaining == 0 { try FileManager.default.removeItem(at: journalURL); return nil }
        return "备份搬移仍有 \(remaining) 个文件未处理；有效原件与副本已保留，请检查目录后重试。"
    }

    /// Persist a manifest before copying. Resume by revalidating both files,
    /// never by trusting the stored stage alone.
    private func migrate(from source: URL, to target: URL, commit: () throws -> Void) throws -> String? {
        if Self.canonicalFallback(source).path == Self.canonicalFallback(target).path { try commit(); return nil }
        guard !hasPendingMigration() else { throw BackupDirectoryError.migrationPending }
        let files = try backupFiles(source)
        let sourceBookmark = Self.canonicalFallback(source) == defaultDirectoryURL ? nil : try codec.encode(source.deletingLastPathComponent())
        let targetBookmark = Self.canonicalFallback(target) == defaultDirectoryURL ? nil : try codec.encode(target.deletingLastPathComponent())
        let originals = try files.map { file -> (URL, Data) in (file.url, try boundedRead(file.url)) }
        let manifest = try originals.map { original, bytes -> Migration.File in
            let destination = target.appendingPathComponent(original.lastPathComponent)
            let exists = FileManager.default.fileExists(atPath: destination.path)
            if exists { guard try boundedRead(destination) == bytes else { throw BackupDirectoryError.migrationConflict } }
            return Migration.File(name: original.lastPathComponent, digest: digest(bytes), createdDestination: !exists)
        }
        var journal = Migration(source: source, target: target, sourceBookmark: sourceBookmark, targetBookmark: targetBookmark, phase: "copying", files: manifest)
        try saveMigration(journal)
        var copied: [URL] = []
        do {
            for (index, pair) in originals.enumerated() {
                let (original, bytes) = pair
                let destination = target.appendingPathComponent(original.lastPathComponent)
                if manifest[index].createdDestination {
                    copied.append(destination)
                    try migrationIO.write(bytes, destination)
                    try FileManager.default.setAttributes([.modificationDate: files[index].date], ofItemAtPath: destination.path)
                }
                guard try migrationIO.read(destination) == bytes else { throw BackupDirectoryError.sourceChanged }
            }
            guard Set(try backupFiles(source).map { $0.url.lastPathComponent }) == Set(files.map { $0.url.lastPathComponent }) else { throw BackupDirectoryError.sourceChanged }
            for (original, bytes) in originals { guard try boundedRead(original) == bytes else { throw BackupDirectoryError.sourceChanged } }
            journal.phase = "verified"
            try saveMigration(journal)
        } catch {
            var rollbackFailed = false
            for destination in copied {
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        guard let file = manifest.first(where: { $0.name == destination.lastPathComponent }),
                              digest(try boundedRead(source.appendingPathComponent(file.name))) == file.digest,
                              digest(try boundedRead(destination)) == file.digest else { throw BackupDirectoryError.sourceChanged }
                        try migrationIO.remove(destination)
                    }
                } catch { rollbackFailed = true }
            }
            if !rollbackFailed { try? FileManager.default.removeItem(at: journalURL) }
            throw error
        }
        try commit()
        // The active directory is the durable commit marker, even if termination
        // happens before any old copy is removed.
        return try retryPendingMigration()
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

    public func summary() throws -> BackupSummary {
        try withDirectory { directory in
            let entries = try listInDirectory(directory)
            let total = try entries.reduce(Int64(0)) { sum, entry in
                let attrs = try FileManager.default.attributesOfItem(atPath: entry.fileURL.path)
                return sum + ((attrs[.size] as? NSNumber)?.int64Value ?? 0)
            }
            return BackupSummary(count: entries.count, totalBytes: total, latestDate: entries.map(\.createdAt).max(), pendingMigration: hasPendingMigration())
        }
    }

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
        let saved = try selection()
        if let bytes = saved.bookmark {
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
        if saved.path != nil { throw BackupDirectoryError.bookmarkUnavailable }
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
        if !hasPendingMigration() {
            for old in try backupFiles(directory).dropFirst(Self.retentionCount) { try FileManager.default.removeItem(at: old.url) }
        }
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
