import Foundation

public struct AccountDraft: Sendable {
    public let displayName: String
    public let providerKind: ProviderKind
    public let baseURL: String
    public let credential: ProviderCredential
    public let lowBalanceThreshold: Decimal?

    public init(
        displayName: String,
        providerKind: ProviderKind,
        baseURL: String,
        credential: ProviderCredential,
        lowBalanceThreshold: Decimal? = Decimal(20)
    ) {
        self.displayName = displayName
        self.providerKind = providerKind
        self.baseURL = baseURL
        self.credential = credential
        self.lowBalanceThreshold = lowBalanceThreshold
    }
}

@MainActor
public final class AccountService {
    private let repository: any LocalRepository
    private let credentialStore: any CredentialStore
    private let adapters: ProviderAdapterRegistry
    private let rateService: RateService
    private let calendar: Calendar

    public init(
        repository: any LocalRepository,
        credentialStore: any CredentialStore,
        adapters: ProviderAdapterRegistry,
        rateService: RateService = RateService(),
        calendar: Calendar = .current
    ) {
        self.repository = repository
        self.credentialStore = credentialStore
        self.adapters = adapters
        self.rateService = rateService
        self.calendar = calendar
    }

    public func addAccount(_ draft: AccountDraft) async throws -> AccountConfiguration {
        let account = try makeAccount(from: draft)
        let adapter = try adapters.adapter(for: account.providerKind)

        // Validate against the provider before persisting any local state.
        let rate = try await adapter.fetchAccountRate(for: account, credential: draft.credential)
        try await adapter.validateAccount(account, credential: draft.credential)
        let snapshot = try await adapter.fetchSnapshot(
            for: account,
            credential: draft.credential,
            rate: rate,
            now: Date(),
            calendar: calendar
        )

        try await credentialStore.save(draft.credential, reference: account.credentialReference)
        do {
            try repository.upsertAccount(account)
            try repository.upsertSnapshot(snapshot)
            // The first verified snapshot must seed the trend history as well;
            // otherwise a newly added account shows no current-day data until
            // the next scheduled refresh.
            try repository.upsertDailyUsage(DailyUsageRecord(
                accountID: account.id,
                day: calendar.startOfDay(for: snapshot.fetchedAt),
                spend: snapshot.todaySpend,
                updatedAt: snapshot.fetchedAt
            ))
            // Pipio has a documented range-stat endpoint. Backfill available
            // daily aggregates at creation time; providers without a public
            // history endpoint return an empty list through the protocol.
            let history = (try? await adapter.fetchDailyUsage(
                for: account,
                credential: draft.credential,
                rate: rate,
                endingAt: snapshot.fetchedAt,
                days: 7,
                calendar: calendar
            )) ?? []
            for record in history { try repository.upsertDailyUsage(record) }
            await rateService.seed(rate)
            return account
        } catch {
            try? await credentialStore.delete(reference: account.credentialReference)
            try? repository.deleteAccount(id: account.id)
            throw error
        }
    }

    /// Performs the same live provider checks as account creation without writing
    /// the account or credential. The UI uses this for the explicit probe button.
    public func probe(_ draft: AccountDraft) async throws -> ProviderSnapshot {
        let account = try makeAccount(from: draft)
        let adapter = try adapters.adapter(for: account.providerKind)
        let rate = try await adapter.fetchAccountRate(for: account, credential: draft.credential)
        try await adapter.validateAccount(account, credential: draft.credential)
        return try await adapter.fetchSnapshot(
            for: account,
            credential: draft.credential,
            rate: rate,
            now: Date(),
            calendar: calendar
        )
    }

    private func makeAccount(from draft: AccountDraft) throws -> AccountConfiguration {
        let name = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let inputURL = URL(string: draft.baseURL) else {
            throw ProviderError.invalidBaseURL
        }

        let origin: URL
        switch draft.providerKind {
        case .pipio:
            origin = try ProviderURLNormalizer.pipio(from: inputURL).origin
        case .deepseek:
            origin = try ProviderURLNormalizer.secureOrigin(from: inputURL)
        case .custom:
            throw ProviderError.unsupportedProvider
        }

        let sortOrder = (try repository.fetchAccounts().map(\.sortOrder).max() ?? -1) + 1
        return AccountConfiguration(
            displayName: name,
            providerKind: draft.providerKind,
            siteOrigin: origin,
            isEnabled: true,
            lowBalanceThreshold: draft.lowBalanceThreshold,
            sortOrder: sortOrder
        )
    }

    public func updateAccount(
        accountID: UUID,
        displayName: String,
        lowBalanceThreshold: Decimal?,
        replacementCredential: ProviderCredential? = nil,
        manualUSDToCNY: ManualExchangeRateUpdate = .unchanged
    ) async throws {
        guard var account = try repository.account(id: accountID) else { return }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProviderError.invalidBaseURL }

        if case let .set(value) = manualUSDToCNY {
            if let value, !USDToCNYRate.isValid(value) {
                throw AccountServiceError.invalidExchangeRate
            }
            account.manualUSDToCNY = value
        }

        // Keep the previous credential until the metadata write succeeds. If the
        // repository fails after saving a replacement, restore the old value so an
        // edit cannot leave the account pointing at an uncommitted secret.
        let previousCredential: ProviderCredential?
        if replacementCredential != nil {
            do {
                previousCredential = try await credentialStore.read(reference: account.credentialReference)
            } catch CredentialStoreError.notFound {
                previousCredential = nil
            }
        } else {
            previousCredential = nil
        }

        if let replacementCredential {
            let adapter = try adapters.adapter(for: account.providerKind)
            _ = try await adapter.fetchAccountRate(for: account, credential: replacementCredential)
            try await adapter.validateAccount(account, credential: replacementCredential)
            try await credentialStore.save(replacementCredential, reference: account.credentialReference)
        }
        account.displayName = name
        account.lowBalanceThreshold = lowBalanceThreshold
        account.updatedAt = nextUpdateDate(after: account.updatedAt)
        do {
            try repository.upsertAccount(account)
        } catch {
            if replacementCredential != nil {
                do {
                    if let previousCredential {
                        try await credentialStore.save(previousCredential, reference: account.credentialReference)
                    } else {
                        try await credentialStore.delete(reference: account.credentialReference)
                    }
                } catch {
                    throw AccountServiceError.credentialRollbackFailed
                }
            }
            throw error
        }
    }

    // The existing sync format keeps whole seconds. Advance local edits at
    // least one serialized tick so a rapid second edit cannot lose to its own
    // older copy during the next exchange.
    private func nextUpdateDate(after previous: Date) -> Date {
        Date(timeIntervalSince1970: max(floor(Date().timeIntervalSince1970), floor(previous.timeIntervalSince1970) + 1))
    }

    public func setEnabled(accountID: UUID, enabled: Bool) throws {
        guard var account = try repository.account(id: accountID) else { return }
        account.isEnabled = enabled
        account.updatedAt = nextUpdateDate(after: account.updatedAt)
        try repository.upsertAccount(account)
    }

    public func deleteAccount(id: UUID) async throws {
        guard let account = try repository.account(id: id) else { return }
        try await credentialStore.delete(reference: account.credentialReference)
        try repository.deleteAccount(id: id)
        await rateService.remove(accountID: id)
    }
}

public enum AccountServiceError: LocalizedError {
    case credentialRollbackFailed
    case invalidExchangeRate

    public var errorDescription: String? {
        switch self {
        case .credentialRollbackFailed:
            return "账户保存失败，且无法恢复本机凭据。请检查本地存储后重新录入凭据。"
        case .invalidExchangeRate:
            return "美元/人民币汇率必须是大于 0 的有效数字（例如 7.30）；留空使用站点汇率。"
        }
    }
}
