import Foundation

public protocol LocalRepository: AnyObject {
    @MainActor func fetchAccounts() throws -> [AccountConfiguration]
    @MainActor func account(id: UUID) throws -> AccountConfiguration?
    @MainActor func upsertAccount(_ account: AccountConfiguration) throws
    @MainActor func deleteAccount(id: UUID) throws
    @MainActor func snapshot(accountID: UUID) throws -> ProviderSnapshot?
    @MainActor func upsertSnapshot(_ snapshot: ProviderSnapshot) throws
    /// Commit a refreshed snapshot and its history together, or leave both unchanged.
    @MainActor func commitRefresh(_ snapshot: ProviderSnapshot, dailyUsage: DailyUsageRecord?) throws
    @MainActor func dailyUsage(accountID: UUID, limit: Int?) throws -> [DailyUsageRecord]
    @MainActor func commitDailyUsage(_ records: [DailyUsageRecord]) throws
    @MainActor func upsertDailyUsage(_ record: DailyUsageRecord) throws
    @MainActor func settings() throws -> RelaySettings
    @MainActor func updateSettings(_ settings: RelaySettings) throws
    @MainActor func syncData() throws -> RelaySyncData
    @MainActor func mergeSyncData(_ data: RelaySyncData) throws
    /// Apply a premerged result only while its source local snapshot is still current.
    @MainActor func replaceNonsecretData(_ data: RelaySyncData, expected: RelaySyncData) throws -> Bool
    @MainActor func applyPreparedSyncData(_ data: RelaySyncData, expected: RelaySyncData) throws -> Bool
}

extension LocalRepository {
    @MainActor public func replaceNonsecretData(_ data: RelaySyncData, expected: RelaySyncData) throws -> Bool {
        throw LocalRepositoryError.unavailable
    }

    @MainActor public func commitDailyUsage(_ records: [DailyUsageRecord]) throws {
        let current = try syncData()
        let ids = Set(records.map(\.id))
        let candidate = RelaySyncData(accounts: current.accounts, snapshots: current.snapshots, dailyUsage: current.dailyUsage.filter { !ids.contains($0.id) } + records, settings: current.settings, settingsUpdatedAt: current.settingsUpdatedAt, deletedAccountIDs: current.deletedAccountIDs)
        guard try applyPreparedSyncData(candidate, expected: current) else { throw LocalRepositoryError.unavailable }
    }

    @MainActor public func applyPreparedSyncData(_ data: RelaySyncData, expected: RelaySyncData) throws -> Bool {
        guard try syncData().hasSameContent(as: expected) else { return false }
        try mergeSyncData(data)
        return true
    }
}

extension RelaySyncData {
    /// Portable UUID references must never replace a device's saved credential mapping.
    func preservingLocalCredentialReferences(from local: RelaySyncData) -> RelaySyncData {
        let existing = Dictionary(local.accounts.map { ($0.id, $0) }, uniquingKeysWith: { left, _ in left })
        let mapped = accounts.map { incoming -> AccountConfiguration in
            var account = incoming
            if let previous = existing[account.id], previous.providerKind == account.providerKind, previous.siteOrigin == account.siteOrigin {
                account.credentialReference = previous.credentialReference
            } else {
                account.credentialReference = UUID().uuidString
            }
            return account
        }
        return RelaySyncData(schemaVersion: schemaVersion, exportedAt: exportedAt, accounts: mapped,
            snapshots: snapshots, dailyUsage: dailyUsage, settings: settings,
            settingsUpdatedAt: settingsUpdatedAt, deletedAccountIDs: deletedAccountIDs)
    }

    func hasSameContent(as other: RelaySyncData) -> Bool {
        schemaVersion == other.schemaVersion && accounts == other.accounts && snapshots == other.snapshots &&
        dailyUsage == other.dailyUsage && settings == other.settings && settingsUpdatedAt == other.settingsUpdatedAt &&
        deletedAccountIDs == other.deletedAccountIDs
    }
}

public enum LocalRepositoryError: LocalizedError, Equatable, Sendable {
    case unavailable
    case unreadable
    case corruptData
    case unsupportedVersion

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "本地存储暂时不可用，未保存更改。"
        case .unreadable: return "本地数据未能载入，请检查文件权限或是否可读取。"
        case .corruptData: return "本地数据未能载入，文件内容无法解析。原文件已保留。"
        case .unsupportedVersion: return "本地数据版本不受支持，请使用兼容的 Relay 版本。原文件已保留。"
        }
    }
}

/// Versioned local store for non-secret business data. Credentials are never
/// part of this schema and are referenced only by a stable account UUID.
@MainActor
public final class FileLocalRepository: LocalRepository {
    private struct State: Codable {
        var schemaVersion: Int
        var accounts: [AccountConfiguration]
        var snapshots: [ProviderSnapshot]
        var dailyUsage: [DailyUsageRecord]
        var settings: RelaySettings
        var settingsUpdatedAt: Date?
        var deletedAccountIDs: [UUID: Date]

        init(
            schemaVersion: Int = 2,
            accounts: [AccountConfiguration] = [],
            snapshots: [ProviderSnapshot] = [],
            dailyUsage: [DailyUsageRecord] = [],
            settings: RelaySettings = RelaySettings(),
            settingsUpdatedAt: Date? = nil,
            deletedAccountIDs: [UUID: Date] = [:]
        ) {
            self.schemaVersion = schemaVersion
            self.accounts = accounts
            self.snapshots = snapshots
            self.dailyUsage = dailyUsage
            self.settingsUpdatedAt = settingsUpdatedAt
            self.settings = settings
            self.deletedAccountIDs = deletedAccountIDs
        }

        enum CodingKeys: String, CodingKey { case schemaVersion, accounts, snapshots, dailyUsage, settings, settingsUpdatedAt, deletedAccountIDs }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            guard schemaVersion <= 2 else { throw LocalRepositoryError.unsupportedVersion }
            accounts = try c.decodeIfPresent([AccountConfiguration].self, forKey: .accounts) ?? []
            snapshots = try c.decodeIfPresent([ProviderSnapshot].self, forKey: .snapshots) ?? []
            dailyUsage = try c.decodeIfPresent([DailyUsageRecord].self, forKey: .dailyUsage) ?? []
            settingsUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .settingsUpdatedAt)
            settings = try c.decodeIfPresent(RelaySettings.self, forKey: .settings) ?? RelaySettings()
            deletedAccountIDs = try c.decodeIfPresent([UUID: Date].self, forKey: .deletedAccountIDs) ?? [:]
            guard settings.schemaVersion <= RelaySettings.currentSchemaVersion else { throw LocalRepositoryError.unsupportedVersion }
        }
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var state: State
    private var historyByAccount: [UUID: [DailyUsageRecord]] = [:]
    /// Aggregate, process-local observations only; never encoded or synced.
    public private(set) var performanceDiagnostics = RepositoryPerformanceDiagnostics()

    public init(fileURL: URL? = nil) throws {
        let reloadStarted = RepositoryPerformanceClock.now()
        var loadedBytes = 0
        let resolvedURL: URL
        if let fileURL {
            resolvedURL = fileURL
        } else {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first else { throw LocalRepositoryError.unavailable }
            resolvedURL = applicationSupport
                .appendingPathComponent("cloud.dinghao.relay", isDirectory: true)
                .appendingPathComponent("relay-local-v1.json", isDirectory: false)
        }
        self.fileURL = resolvedURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data: Data?
        do { data = try Data(contentsOf: resolvedURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { data = nil }
        catch { throw LocalRepositoryError.unreadable }
        if let data {
            do { try Self.applyOwnerOnlyPermissions(to: resolvedURL) }
            catch { throw LocalRepositoryError.unreadable }
            do {
                state = try decoder.decode(State.self, from: data)
                loadedBytes = data.count
            } catch let error as LocalRepositoryError {
                throw error
            } catch { throw LocalRepositoryError.corruptData }
        } else {
            state = State()
        }
        rebuildHistoryIndex()
        updateCapacityDiagnostics(fileBytes: loadedBytes)
        performanceDiagnostics.reloadMilliseconds = RepositoryPerformanceClock.elapsedMilliseconds(since: reloadStarted)
    }

    public func fetchAccounts() throws -> [AccountConfiguration] {
        state.accounts.sorted {
            if $0.sortOrder == $1.sortOrder { return $0.createdAt < $1.createdAt }
            return $0.sortOrder < $1.sortOrder
        }
    }

    public func account(id: UUID) throws -> AccountConfiguration? {
        state.accounts.first(where: { $0.id == id })
    }

    public func upsertAccount(_ account: AccountConfiguration) throws {
        var candidate = state
        if let index = candidate.accounts.firstIndex(where: { $0.id == account.id }) {
            candidate.accounts[index] = account
        } else {
            candidate.accounts.append(account)
        }
        try commit(candidate)
    }

    public func deleteAccount(id: UUID) throws {
        var candidate = state
        candidate.accounts.removeAll(where: { $0.id == id })
        candidate.snapshots.removeAll(where: { $0.accountID == id })
        candidate.dailyUsage.removeAll(where: { $0.accountID == id })
        candidate.deletedAccountIDs[id] = max(
            Date(),
            state.accounts.first(where: { $0.id == id })?.updatedAt ?? .distantPast,
            state.deletedAccountIDs[id] ?? .distantPast
        )
        try commit(candidate)
    }

    public func snapshot(accountID: UUID) throws -> ProviderSnapshot? {
        state.snapshots.first(where: { $0.accountID == accountID })
    }

    public func upsertSnapshot(_ snapshot: ProviderSnapshot) throws {
        var candidate = state
        if let index = candidate.snapshots.firstIndex(where: { $0.accountID == snapshot.accountID }) {
            candidate.snapshots[index] = snapshot
        } else {
            candidate.snapshots.append(snapshot)
        }
        try commit(candidate)
    }

    public func commitRefresh(_ snapshot: ProviderSnapshot, dailyUsage record: DailyUsageRecord?) throws {
        var candidate = state
        candidate.snapshots.removeAll { $0.accountID == snapshot.accountID }
        candidate.snapshots.append(snapshot)
        if let record {
            candidate.dailyUsage.removeAll { $0.id == record.id }
            candidate.dailyUsage.append(record)
            pruneHistoryIfNeeded(&candidate)
        }
        try commit(candidate)
    }

    public func dailyUsage(accountID: UUID, limit: Int? = nil) throws -> [DailyUsageRecord] {
        let records = historyByAccount[accountID] ?? []
        guard let limit, limit > 0 else { return records }
        return Array(records.suffix(limit))
    }

    public func commitDailyUsage(_ records: [DailyUsageRecord]) throws {
        var candidate = state
        let ids = Set(records.map(\.id))
        candidate.dailyUsage.removeAll { ids.contains($0.id) }
        candidate.dailyUsage.append(contentsOf: records)
        pruneHistoryIfNeeded(&candidate)
        try commit(candidate)
    }

    public func upsertDailyUsage(_ record: DailyUsageRecord) throws {
        var candidate = state
        if let index = candidate.dailyUsage.firstIndex(where: { $0.id == record.id }) {
            candidate.dailyUsage[index] = record
        } else {
            candidate.dailyUsage.append(record)
        }
        pruneHistoryIfNeeded(&candidate)
        try commit(candidate)
    }

    public func settings() throws -> RelaySettings { state.settings }

    public func updateSettings(_ settings: RelaySettings) throws {
        var candidate = state
        var oldPreferences = state.settings
        oldPreferences.iCloudFileSyncEnabled = settings.iCloudFileSyncEnabled
        if oldPreferences != settings {
            candidate.settingsUpdatedAt = Date(timeIntervalSince1970: max(
                floor(Date().timeIntervalSince1970),
                (state.settingsUpdatedAt ?? .distantPast).timeIntervalSince1970 + 1
            ))
        }
        candidate.settings = settings
        pruneHistoryIfNeeded(&candidate)
        try commit(candidate)
    }

    public func syncData() throws -> RelaySyncData {
        RelaySyncData(
            accounts: state.accounts,
            snapshots: state.snapshots,
            dailyUsage: state.dailyUsage,
            settings: state.settings,
            settingsUpdatedAt: state.settingsUpdatedAt,
            deletedAccountIDs: state.deletedAccountIDs
        )
    }

    public func mergeSyncData(_ data: RelaySyncData) throws {
        let merged = try SyncMerge.merge(syncData(), data)
        try commitSyncedData(merged)
    }

    public func replaceNonsecretData(_ data: RelaySyncData, expected: RelaySyncData) throws -> Bool {
        guard try syncData().hasSameContent(as: expected) else { return false }
        try commitSyncedData(data, preserveCredentials: false)
        return true
    }

    public func applyPreparedSyncData(_ data: RelaySyncData, expected: RelaySyncData) throws -> Bool {
        guard try syncData().hasSameContent(as: expected) else { return false }
        try commitSyncedData(data)
        return true
    }

    private func commitSyncedData(_ incoming: RelaySyncData, preserveCredentials: Bool = true) throws {
        let merged = preserveCredentials ? incoming.preservingLocalCredentialReferences(from: try syncData()) : incoming
        guard merged.schemaVersion == RelaySyncData.currentSchemaVersion,
              merged.settings.schemaVersion == RelaySettings.currentSchemaVersion else { throw LocalRepositoryError.unsupportedVersion }
        var candidate = state
        candidate.accounts = merged.accounts
        candidate.snapshots = merged.snapshots
        candidate.dailyUsage = merged.dailyUsage
        candidate.settings = merged.settings
        candidate.settingsUpdatedAt = merged.settingsUpdatedAt
        candidate.deletedAccountIDs = merged.deletedAccountIDs
        pruneHistoryIfNeeded(&candidate)
        try commit(candidate)
    }

    private func pruneHistoryIfNeeded(_ candidate: inout State) {
        let cutoff: Date?
        switch candidate.settings.historyRetention {
        case .oneMonth:
            cutoff = Calendar.current.date(byAdding: .month, value: -1, to: Date())
        case .halfYear:
            cutoff = Calendar.current.date(byAdding: .month, value: -6, to: Date())
        case .oneYear:
            cutoff = Calendar.current.date(byAdding: .year, value: -1, to: Date())
        case .forever:
            cutoff = nil
        }
        guard let cutoff else { return }
        candidate.dailyUsage.removeAll { $0.day < cutoff }
    }

    private func commit(_ candidate: State) throws {
        let started = RepositoryPerformanceClock.now()
        var succeeded = false
        defer {
            // Attempt timings may change on failure; committed capacity and cache do not.
            performanceDiagnostics.commitMilliseconds = RepositoryPerformanceClock.elapsedMilliseconds(since: started)
            performanceDiagnostics.lastCommitSucceeded = succeeded
        }
        let data: Data
        do {
            data = try encoder.encode(candidate)
            try PrivateFileWriter.write(data, to: fileURL)
        } catch { throw LocalRepositoryError.unavailable }
        // All fallible work remains before the atomic commit point. The index is
        // a derived projection, not a second persisted state or sync payload.
        state = candidate
        rebuildHistoryIndex()
        updateCapacityDiagnostics(fileBytes: data.count)
        succeeded = true
    }

    private func rebuildHistoryIndex() {
        historyByAccount = Dictionary(grouping: state.dailyUsage, by: \.accountID)
            .mapValues { $0.sorted { $0.day < $1.day } }
    }

    private func updateCapacityDiagnostics(fileBytes: Int) {
        performanceDiagnostics.accountCount = state.accounts.count
        performanceDiagnostics.historyCount = state.dailyUsage.count
        performanceDiagnostics.maximumHistoryCountPerAccount = historyByAccount.values.map(\.count).max() ?? 0
        performanceDiagnostics.fileBytes = fileBytes
    }

    private static func applyOwnerOnlyPermissions(to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch { throw LocalRepositoryError.unavailable }
    }
}

@MainActor
public final class InMemoryLocalRepository: LocalRepository {
    private var accounts: [UUID: AccountConfiguration] = [:]
    private var snapshots: [UUID: ProviderSnapshot] = [:]
    private var usage: [String: DailyUsageRecord] = [:]
    private var storedSettings = RelaySettings()
    private var settingsUpdatedAt: Date?
    private var deletedAccountIDs: [UUID: Date] = [:]

    public init() {}
    public func fetchAccounts() throws -> [AccountConfiguration] {
        accounts.values.sorted { $0.sortOrder == $1.sortOrder ? $0.createdAt < $1.createdAt : $0.sortOrder < $1.sortOrder }
    }
    public func account(id: UUID) throws -> AccountConfiguration? { accounts[id] }
    public func upsertAccount(_ account: AccountConfiguration) throws { accounts[account.id] = account }
    public func deleteAccount(id: UUID) throws {
        deletedAccountIDs[id] = max(Date(), accounts[id]?.updatedAt ?? .distantPast, deletedAccountIDs[id] ?? .distantPast)
        accounts.removeValue(forKey: id); snapshots.removeValue(forKey: id)
        usage = usage.filter { $0.value.accountID != id }
    }
    public func snapshot(accountID: UUID) throws -> ProviderSnapshot? { snapshots[accountID] }
    public func upsertSnapshot(_ snapshot: ProviderSnapshot) throws { snapshots[snapshot.accountID] = snapshot }
    public func commitRefresh(_ snapshot: ProviderSnapshot, dailyUsage record: DailyUsageRecord?) throws {
        snapshots[snapshot.accountID] = snapshot
        if let record {
            usage[record.id] = record
            pruneHistoryIfNeeded()
        }
    }
    public func dailyUsage(accountID: UUID, limit: Int?) throws -> [DailyUsageRecord] {
        let all = usage.values.filter { $0.accountID == accountID }.sorted { $0.day < $1.day }
        guard let limit, limit > 0 else { return all }
        return Array(all.suffix(limit))
    }
    public func commitDailyUsage(_ records: [DailyUsageRecord]) throws {
        for record in records { usage[record.id] = record }
        pruneHistoryIfNeeded()
    }
    public func upsertDailyUsage(_ record: DailyUsageRecord) throws {
        usage[record.id] = record
        pruneHistoryIfNeeded()
    }
    public func settings() throws -> RelaySettings { storedSettings }
    public func updateSettings(_ settings: RelaySettings) throws {
        var oldPreferences = storedSettings
        oldPreferences.iCloudFileSyncEnabled = settings.iCloudFileSyncEnabled
        if oldPreferences != settings {
            settingsUpdatedAt = Date(timeIntervalSince1970: max(
                floor(Date().timeIntervalSince1970),
                (settingsUpdatedAt ?? .distantPast).timeIntervalSince1970 + 1
            ))
        }
        storedSettings = settings
        pruneHistoryIfNeeded()
    }
    public func syncData() throws -> RelaySyncData {
        RelaySyncData(accounts: Array(accounts.values), snapshots: Array(snapshots.values), dailyUsage: Array(usage.values), settings: storedSettings, settingsUpdatedAt: settingsUpdatedAt, deletedAccountIDs: deletedAccountIDs)
    }
    public func mergeSyncData(_ data: RelaySyncData) throws {
        let local = try syncData()
        let merged = try SyncMerge.merge(local, data).preservingLocalCredentialReferences(from: local)
        accounts = Dictionary(uniqueKeysWithValues: merged.accounts.map { ($0.id, $0) })
        snapshots = Dictionary(uniqueKeysWithValues: merged.snapshots.map { ($0.accountID, $0) })
        usage = Dictionary(uniqueKeysWithValues: merged.dailyUsage.map { ($0.id, $0) })
        storedSettings = merged.settings
        settingsUpdatedAt = merged.settingsUpdatedAt
        deletedAccountIDs = merged.deletedAccountIDs
        pruneHistoryIfNeeded()
    }

    public func replaceNonsecretData(_ data: RelaySyncData, expected: RelaySyncData) throws -> Bool {
        guard try syncData().hasSameContent(as: expected) else { return false }
        guard data.schemaVersion == RelaySyncData.currentSchemaVersion,
              data.settings.schemaVersion == RelaySettings.currentSchemaVersion else { throw LocalRepositoryError.unsupportedVersion }
        accounts = Dictionary(uniqueKeysWithValues: data.accounts.map { ($0.id, $0) })
        snapshots = Dictionary(uniqueKeysWithValues: data.snapshots.map { ($0.accountID, $0) })
        usage = Dictionary(uniqueKeysWithValues: data.dailyUsage.map { ($0.id, $0) })
        storedSettings = data.settings
        settingsUpdatedAt = data.settingsUpdatedAt
        deletedAccountIDs = data.deletedAccountIDs
        pruneHistoryIfNeeded()
        return true
    }

    private func pruneHistoryIfNeeded() {
        let cutoff: Date?
        switch storedSettings.historyRetention {
        case .oneMonth:
            cutoff = Calendar.current.date(byAdding: .month, value: -1, to: Date())
        case .halfYear:
            cutoff = Calendar.current.date(byAdding: .month, value: -6, to: Date())
        case .oneYear:
            cutoff = Calendar.current.date(byAdding: .year, value: -1, to: Date())
        case .forever:
            cutoff = nil
        }
        guard let cutoff else { return }
        usage = usage.filter { $0.value.day >= cutoff }
    }
}
