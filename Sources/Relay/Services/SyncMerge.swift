import Foundation

/// Deterministic record-level merge, shared by the file and in-memory stores.
/// Ties have a canonical winner; deletion wins a tie with an account edit.
enum SyncMerge {
    static func merge(_ local: RelaySyncData, _ remote: RelaySyncData) throws -> RelaySyncData {
        guard local.schemaVersion == RelaySyncData.currentSchemaVersion,
              remote.schemaVersion == RelaySyncData.currentSchemaVersion,
              remote.settings.schemaVersion == RelaySettings.currentSchemaVersion else {
            throw LocalRepositoryError.corruptData
        }
        let tombstones = local.deletedAccountIDs.merging(remote.deletedAccountIDs, uniquingKeysWith: max)
        let accounts = try records(local.accounts + remote.accounts, id: { $0.id.uuidString }, date: { $0.updatedAt })
            .filter { second(tombstones[$0.id] ?? .distantPast) < second($0.updatedAt) }
        let accountIDs = Set(accounts.map(\.id))
        let snapshots = try records(local.snapshots + remote.snapshots, id: { $0.accountID.uuidString }, date: { $0.fetchedAt })
            .filter { accountIDs.contains($0.accountID) }
        let usage = try records(local.dailyUsage + remote.dailyUsage, id: { $0.id }, date: { $0.updatedAt })
            .filter { accountIDs.contains($0.accountID) }

        var localPreferences = local.settings
        var remotePreferences = remote.settings
        // Directory authorization and sync opt-in belong to this device only.
        localPreferences.iCloudFileSyncEnabled = false
        remotePreferences.iCloudFileSyncEnabled = false
        let localDate = local.settingsUpdatedAt ?? .distantPast
        let remoteDate = remote.settingsUpdatedAt ?? .distantPast
        var preferences = try winner(localPreferences, remotePreferences, leftDate: localDate, rightDate: remoteDate)
        preferences.iCloudFileSyncEnabled = local.settings.iCloudFileSyncEnabled
        return RelaySyncData(
            exportedAt: max(local.exportedAt, remote.exportedAt),
            accounts: accounts, snapshots: snapshots, dailyUsage: usage,
            settings: preferences,
            settingsUpdatedAt: max(localDate, remoteDate),
            deletedAccountIDs: tombstones
        )
    }

    private static func records<T: Encodable>(_ values: [T], id: (T) -> String, date: (T) -> Date) throws -> [T] {
        var result: [String: T] = [:]
        for value in values {
            let key = id(value)
            if let existing = result[key] {
                result[key] = try winner(existing, value, leftDate: date(existing), rightDate: date(value))
            } else {
                result[key] = value
            }
        }
        return result.keys.sorted().compactMap { result[$0] }
    }

    // Existing v1 JSON uses second-precision ISO8601. Compare at that same
    // precision so a serialized tombstone cannot lose to an in-memory edit
    // from the same second. Deletion wins that tie, on every device.
    private static func second(_ date: Date) -> Double {
        floor(date.timeIntervalSince1970)
    }

    private static func winner<T: Encodable>(_ left: T, _ right: T, leftDate: Date, rightDate: Date) throws -> T {
        if second(leftDate) != second(rightDate) { return second(leftDate) > second(rightDate) ? left : right }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let leftData = try encoder.encode(left)
        let rightData = try encoder.encode(right)
        return leftData.lexicographicallyPrecedes(rightData) ? right : left
    }
}
