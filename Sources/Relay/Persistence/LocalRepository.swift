import Foundation

public protocol LocalRepository: AnyObject {
    @MainActor func fetchAccounts() throws -> [AccountConfiguration]
    @MainActor func account(id: UUID) throws -> AccountConfiguration?
    @MainActor func upsertAccount(_ account: AccountConfiguration) throws
    @MainActor func deleteAccount(id: UUID) throws
    @MainActor func snapshot(accountID: UUID) throws -> ProviderSnapshot?
    @MainActor func upsertSnapshot(_ snapshot: ProviderSnapshot) throws
    @MainActor func dailyUsage(accountID: UUID, limit: Int?) throws -> [DailyUsageRecord]
    @MainActor func upsertDailyUsage(_ record: DailyUsageRecord) throws
    @MainActor func settings() throws -> RelaySettings
    @MainActor func updateSettings(_ settings: RelaySettings) throws
    @MainActor func syncData() throws -> RelaySyncData
    @MainActor func mergeSyncData(_ data: RelaySyncData) throws
}

public enum LocalRepositoryError: Error, Sendable {
    case unavailable
    case corruptData
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
            accounts = try c.decodeIfPresent([AccountConfiguration].self, forKey: .accounts) ?? []
            snapshots = try c.decodeIfPresent([ProviderSnapshot].self, forKey: .snapshots) ?? []
            dailyUsage = try c.decodeIfPresent([DailyUsageRecord].self, forKey: .dailyUsage) ?? []
            settingsUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .settingsUpdatedAt)
            settings = try c.decodeIfPresent(RelaySettings.self, forKey: .settings) ?? RelaySettings()
            deletedAccountIDs = try c.decodeIfPresent([UUID: Date].self, forKey: .deletedAccountIDs) ?? [:]
            guard schemaVersion <= 2 else { throw LocalRepositoryError.corruptData }
        }
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var state: State

    public init(fileURL: URL? = nil) throws {
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

        if FileManager.default.fileExists(atPath: resolvedURL.path) {
            do {
                try Self.applyOwnerOnlyPermissions(to: resolvedURL)
                state = try decoder.decode(State.self, from: Data(contentsOf: resolvedURL))
            } catch let error as LocalRepositoryError {
                throw error
            } catch {
                throw LocalRepositoryError.corruptData
            }
        } else {
            state = State()
        }
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

    public func dailyUsage(accountID: UUID, limit: Int? = nil) throws -> [DailyUsageRecord] {
        let records = state.dailyUsage
            .filter { $0.accountID == accountID }
            .sorted { $0.day < $1.day }
        guard let limit, limit > 0 else { return records }
        return Array(records.suffix(limit))
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
        do {
            try PrivateFileWriter.write(encoder.encode(candidate), to: fileURL)
        } catch { throw LocalRepositoryError.unavailable }
        state = candidate
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
    public func dailyUsage(accountID: UUID, limit: Int?) throws -> [DailyUsageRecord] {
        let all = usage.values.filter { $0.accountID == accountID }.sorted { $0.day < $1.day }
        guard let limit, limit > 0 else { return all }
        return Array(all.suffix(limit))
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
        let merged = try SyncMerge.merge(syncData(), data)
        accounts = Dictionary(uniqueKeysWithValues: merged.accounts.map { ($0.id, $0) })
        snapshots = Dictionary(uniqueKeysWithValues: merged.snapshots.map { ($0.accountID, $0) })
        usage = Dictionary(uniqueKeysWithValues: merged.dailyUsage.map { ($0.id, $0) })
        storedSettings = merged.settings
        settingsUpdatedAt = merged.settingsUpdatedAt
        deletedAccountIDs = merged.deletedAccountIDs
        pruneHistoryIfNeeded()
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
