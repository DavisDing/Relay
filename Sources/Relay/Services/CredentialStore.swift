import Foundation

public enum CredentialStoreError: Error, Sendable, Equatable {
    case encodingFailed
    case decodingFailed
    case notFound
    case directoryCreationFailed
    case writeFailed
}

public protocol CredentialStore: Sendable {
    func save(_ credential: ProviderCredential, reference: String) async throws
    func read(reference: String) async throws -> ProviderCredential
    func delete(reference: String) async throws
}

private struct CredentialFile: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var values: [String: ProviderCredential]

    init(values: [String: ProviderCredential] = [:]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.values = values
    }
}

/// Stores credentials in Relay's private, local application-support directory.
///
/// This is an explicit product decision: Relay does not use Keychain. The file
/// is not part of the sync directory, is created with owner-only permissions,
/// and is never logged or included in exported business data. File permissions
/// protect against other non-privileged users; they do not provide the same
/// hardware-backed protection or user-consent prompts as Keychain.
public actor FileCredentialStore: CredentialStore {
    public static let defaultFileName = "relay-credentials-v1.json"

    private let fileURL: URL
    private var values: [String: ProviderCredential] = [:]
    private var didLoad = false

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    public func save(_ credential: ProviderCredential, reference: String) async throws {
        try loadIfNeeded()
        var candidate = values
        candidate[reference] = credential
        try persist(candidate)
        values = candidate
    }

    public func read(reference: String) async throws -> ProviderCredential {
        try loadIfNeeded()
        guard let credential = values[reference] else {
            throw CredentialStoreError.notFound
        }
        return credential
    }

    public func delete(reference: String) async throws {
        try loadIfNeeded()
        var candidate = values
        guard candidate.removeValue(forKey: reference) != nil else { return }
        try persist(candidate)
        values = candidate
    }

    public func storageURL() -> URL { fileURL }

    private func loadIfNeeded() throws {
        guard !didLoad else { return }
        // Read directly: fileExists also returns false for some access errors.
        // Only an actual ENOENT is safe to interpret as an empty store.
        do {
            _ = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            didLoad = true
            return
        } catch {
            throw CredentialStoreError.decodingFailed
        }
        do {
            try applyOwnerOnlyPermissions()
            let data = try Data(contentsOf: fileURL)
            let file = try JSONDecoder().decode(CredentialFile.self, from: data)
            guard file.schemaVersion == CredentialFile.currentSchemaVersion else {
                throw CredentialStoreError.decodingFailed
            }
            values = file.values
            didLoad = true
        } catch let error as CredentialStoreError {
            throw error
        } catch {
            throw CredentialStoreError.decodingFailed
        }
    }

    private func persist(_ candidate: [String: ProviderCredential]) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(CredentialFile(values: candidate))
        } catch {
            throw CredentialStoreError.encodingFailed
        }
        do {
            try PrivateFileWriter.write(data, to: fileURL)
        } catch {
            throw CredentialStoreError.writeFailed
        }
    }

    private func applyOwnerOnlyPermissions() throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw CredentialStoreError.writeFailed
        }
    }

    private static func defaultFileURL() -> URL {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return applicationSupport
            .appendingPathComponent("cloud.dinghao.relay", isDirectory: true)
            .appendingPathComponent(defaultFileName, isDirectory: false)
    }
}

#if DEBUG
/// In-memory store for previews and local business-logic checks.
public actor InMemoryCredentialStore: CredentialStore {
    private var values: [String: ProviderCredential] = [:]

    public init() {}

    public func save(_ credential: ProviderCredential, reference: String) async throws {
        values[reference] = credential
    }

    public func read(reference: String) async throws -> ProviderCredential {
        guard let value = values[reference] else { throw CredentialStoreError.notFound }
        return value
    }

    public func delete(reference: String) async throws {
        values.removeValue(forKey: reference)
    }
}
#endif
