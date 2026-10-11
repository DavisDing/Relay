import Foundation

/// Startup storage failures stay separate from transient provider errors.
public enum StorageAvailability: Equatable, Sendable {
    case available
    case unavailable(LocalRepositoryError)

    public var isAvailable: Bool { self == .available }
    public var message: String? {
        guard case .unavailable(let error) = self else { return nil }
        return error.localizedDescription
    }
}

/// Keeps services bound to one repository identity while retrying a failed open.
/// There is no writable empty fallback. Recovery requires an explicit validated backup and original-file comparison.
@MainActor
public final class RecoverableLocalRepository: LocalRepository {
    private var backing: (any LocalRepository)?
    private let recoveryFileURL: URL?
    private let open: @MainActor () throws -> any LocalRepository
    public private(set) var availability: StorageAvailability

    public init(recoveryFileURL: URL? = nil, open: @escaping @MainActor () throws -> any LocalRepository) {
        self.recoveryFileURL = recoveryFileURL
        self.open = open
        do {
            backing = try Self.validated(open())
            availability = .available
        } catch {
            availability = .unavailable(Self.classify(error))
        }
    }

    public init(error: Error, recoveryFileURL: URL? = nil, open: @escaping @MainActor () throws -> any LocalRepository) {
        self.recoveryFileURL = recoveryFileURL
        self.open = open
        availability = .unavailable(Self.classify(error))
    }

    public func recoveryOriginal() throws -> Data {
        guard availability == .unavailable(.corruptData), let recoveryFileURL else { throw LocalRepositoryError.unavailable }
        return try FileLocalRepository.recoveryOriginal(at: recoveryFileURL)
    }

    @discardableResult
    public func recover(_ backup: RelaySyncData, expectedOriginal: Data) throws -> URL {
        guard availability == .unavailable(.corruptData), let recoveryFileURL else { throw LocalRepositoryError.unavailable }
        let preserved = try FileLocalRepository.recover(backup, at: recoveryFileURL, expectedOriginal: expectedOriginal)
        try retryOpening()
        return preserved
    }

    public var performanceDiagnostics: RepositoryPerformanceDiagnostics? {
        (backing as? FileLocalRepository)?.performanceDiagnostics
    }

    public func retryOpening() throws {
        do {
            let candidate = try Self.validated(open())
            backing = candidate
            availability = .available
        } catch {
            availability = .unavailable(Self.classify(error))
            throw Self.classify(error)
        }
    }

    private static func validated(_ repository: any LocalRepository) throws -> any LocalRepository {
        _ = try repository.settings()
        for account in try repository.fetchAccounts() {
            _ = try repository.snapshot(accountID: account.id)
            _ = try repository.dailyUsage(accountID: account.id, limit: nil)
        }
        return repository
    }

    private static func classify(_ error: Error) -> LocalRepositoryError {
        (error as? LocalRepositoryError) ?? .unreadable
    }

    private func requireBacking() throws -> any LocalRepository {
        guard availability.isAvailable, let backing else {
            if case .unavailable(let error) = availability { throw error }
            throw LocalRepositoryError.unavailable
        }
        return backing
    }

    public func fetchAccounts() throws -> [AccountConfiguration] { try requireBacking().fetchAccounts() }
    public func account(id: UUID) throws -> AccountConfiguration? { try requireBacking().account(id: id) }
    public func upsertAccount(_ account: AccountConfiguration) throws { try requireBacking().upsertAccount(account) }
    public func commitNewAccount(_ account: AccountConfiguration, snapshot: ProviderSnapshot, history: [DailyUsageRecord]) throws {
        try requireBacking().commitNewAccount(account, snapshot: snapshot, history: history)
    }
    public func deleteAccount(id: UUID) throws { try requireBacking().deleteAccount(id: id) }
    public func snapshot(accountID: UUID) throws -> ProviderSnapshot? { try requireBacking().snapshot(accountID: accountID) }
    public func upsertSnapshot(_ snapshot: ProviderSnapshot) throws { try requireBacking().upsertSnapshot(snapshot) }
    public func commitRefresh(_ snapshot: ProviderSnapshot, dailyUsage: DailyUsageRecord?) throws {
        try requireBacking().commitRefresh(snapshot, dailyUsage: dailyUsage)
    }
    public func dailyUsage(accountID: UUID, limit: Int?) throws -> [DailyUsageRecord] {
        try requireBacking().dailyUsage(accountID: accountID, limit: limit)
    }
    public func commitDailyUsage(_ records: [DailyUsageRecord]) throws { try requireBacking().commitDailyUsage(records) }
    public func upsertDailyUsage(_ record: DailyUsageRecord) throws { try requireBacking().upsertDailyUsage(record) }
    public func settings() throws -> RelaySettings { try requireBacking().settings() }
    public func updateSettings(_ settings: RelaySettings) throws { try requireBacking().updateSettings(settings) }
    public func syncData() throws -> RelaySyncData { try requireBacking().syncData() }
    public func replaceNonsecretData(_ data: RelaySyncData, expected: RelaySyncData) throws -> Bool {
        try requireBacking().replaceNonsecretData(data, expected: expected)
    }
    public func applyPreparedSyncData(_ data: RelaySyncData, expected: RelaySyncData) throws -> Bool {
        try requireBacking().applyPreparedSyncData(data, expected: expected)
    }
    public func mergeSyncData(_ data: RelaySyncData) throws { try requireBacking().mergeSyncData(data) }
}
