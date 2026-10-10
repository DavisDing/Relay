import Foundation

@MainActor
enum BackupMigrationChecks {
    private enum Fault: Error { case injected }
    private static func check(_ condition: @autoclosure () throws -> Bool, _ text: String) throws {
        if try !condition() { throw NSError(domain: text, code: 1) }
    }
    static func run() async throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/relay-migration-\(UUID())", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let parent = root.appendingPathComponent("target")
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let suite = "relay-migration-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let codec = BackupDirectoryBookmarkCodec(encode: { Data($0.path.utf8) }, decode: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self), isDirectory: true) })
        let credentials = root.appendingPathComponent("credentials")
        var writes = 0
        let io = BackupMigrationIO(write: { bytes, destination in
            writes += 1
            if writes == 2 { throw Fault.injected }
            try PrivateFileWriter.write(bytes, to: destination)
        })
        let service = LocalBackupService(directoryURL: source, preferences: defaults, codec: codec, credentialDirectoryURL: credentials, migrationIO: io)
        let data = RelaySyncData(accounts: [], snapshots: [], dailyUsage: [], settings: RelaySettings())
        let first = try await service.create(data)
        let second = try await service.create(data)
        let unrelated = source.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        do { _ = try await service.selectDirectory(parent); throw NSError(domain: "failed copy accepted", code: 1) }
        catch Fault.injected {}
        try check(manager.fileExists(atPath: first.fileURL.path) && manager.fileExists(atPath: second.fileURL.path), "Copy failure preserves originals")
        try check(defaults.object(forKey: LocalBackupService.bookmarkPreferenceKey) == nil, "Copy failure preserves preference")
        let files = try manager.contentsOfDirectory(atPath: parent.appendingPathComponent("RelayBackups").path)
        try check(files.isEmpty, "Failed partial copy rolled back")
        let normal = LocalBackupService(directoryURL: source, preferences: defaults, codec: codec, credentialDirectoryURL: credentials)
        let destination = parent.appendingPathComponent("RelayBackups").appendingPathComponent(first.fileURL.lastPathComponent)
        try Data("conflict".utf8).write(to: destination)
        do { _ = try await normal.selectDirectory(parent); throw NSError(domain: "conflict accepted", code: 1) }
        catch BackupDirectoryError.migrationConflict {}
        try check(try Data(contentsOf: destination) == Data("conflict".utf8), "Conflict never overwritten")
        try manager.removeItem(at: destination)
        let corrupt = BackupMigrationIO(write: { _, url in try PrivateFileWriter.write(Data("corrupt-copy".utf8), to: url) })
        let verification = LocalBackupService(directoryURL: source, preferences: defaults, codec: codec, credentialDirectoryURL: credentials, migrationIO: corrupt)
        do { _ = try await verification.selectDirectory(parent); throw NSError(domain: "corrupt copy accepted", code: 1) }
        catch BackupDirectoryError.sourceChanged {}
        try check(manager.fileExists(atPath: first.fileURL.path), "Verification failure keeps originals")
        let deletion = BackupMigrationIO(remove: { _ in throw Fault.injected })
        let cleanup = LocalBackupService(directoryURL: source, preferences: defaults, codec: codec, credentialDirectoryURL: credentials, migrationIO: deletion)
        let warning = try await cleanup.selectDirectory(parent)
        try check(warning != nil, "Cleanup failure explicitly reported")
        let moved = try await cleanup.list()
        try check(moved.count == 2 && manager.fileExists(atPath: first.fileURL.path), "Cleanup failure keeps both valid copy and original")
        try check(manager.fileExists(atPath: unrelated.path), "Unrelated file untouched")
        let before = moved
        _ = try await cleanup.selectDirectory(parent)
        let after = try await cleanup.list()
        try check(before == after, "Same directory is a no-op")
        print("PASSED: backup migration copy/verify rollback, collision protection, cleanup warning, no-op and unrelated file preservation")
    }
}
