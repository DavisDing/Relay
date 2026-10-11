import Foundation

/// White-list only. No identifiers, user strings, URLs, paths or raw errors.
public struct RelayDiagnosticReport: Encodable, Sendable {
    let format = "relay-diagnostics-v1"
    let applicationVersion: String
    let systemVersion: String
    let storageState: String
    let accountCount: Int
    let historyCount: Int
    let activeRefreshCount: Int
    let issueCounts: [String: Int]
    let projectionMilliseconds: Double
    let localFileBytes: Int?
    let localLoadMilliseconds: Double?
    let localCommitMilliseconds: Double?
    let lastCommitSucceeded: Bool?
    let syncMilliseconds: Double
    let syncStatus: String
    let backupHasError: Bool

    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
