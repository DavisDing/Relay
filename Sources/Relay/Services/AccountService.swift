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

extension AccountDraft {
    /// Validate all missing fields before URL parsing, provider calls or persistence.
    func validateRequiredFields() throws {
        guard providerKind != .custom else { throw ProviderError.unsupportedProvider }
        func isBlank(_ value: String?) -> Bool {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }
        var fields: [String] = []
        if isBlank(displayName) { fields.append("账号显示名称") }
        if isBlank(baseURL) { fields.append("站点地址") }
        if providerKind == .pipio, isBlank(credential.pipioUserID) { fields.append("Pipio 用户 ID") }
        if isBlank(credential.secret) { fields.append(providerKind == .pipio ? "Pipio 系统令牌" : (providerKind == .workbuddy2api ? "网关 API Key" : "DeepSeek API Key")) }
        if !fields.isEmpty { throw AccountServiceError.missingRequiredFields(fields) }
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
        let historyCalendar = account.providerKind == .deepseek
            ? DeepSeekUsageService.historyCalendar
            : calendar

        try await credentialStore.save(draft.credential, reference: account.credentialReference)
        do {
            try repository.upsertAccount(account)
            try repository.upsertSnapshot(snapshot)
            // The first verified snapshot must seed the trend history as well;
            // otherwise a newly added account shows no current-day data until
            // the next scheduled refresh.
            if account.providerKind != .workbuddy2api {
                try repository.upsertDailyUsage(DailyUsageRecord(
                    accountID: account.id,
                    day: historyCalendar.startOfDay(for: snapshot.fetchedAt),
                    spend: snapshot.todaySpend,
                    updatedAt: snapshot.fetchedAt
                ))
            }
            // Backfill the last seven days for providers with a configured
            // history source. DeepSeek uses the optional platform userToken;
            // without it the adapter makes no platform request.
            let history = (try? await adapter.fetchDailyUsage(
                for: account,
                credential: draft.credential,
                rate: rate,
                endingAt: snapshot.fetchedAt,
                days: 7,
                calendar: historyCalendar
            )) ?? []
            // Today's snapshot is authoritative for the current local day.
            // Never let a historical range response replace it.
            let today = historyCalendar.startOfDay(for: snapshot.fetchedAt)
            for record in history where historyCalendar.startOfDay(for: record.day) != today {
                try repository.upsertDailyUsage(record)
            }
            await rateService.seed(snapshot.rate)
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
        try draft.validateRequiredFields()
        let name = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let inputURL = URL(string: address) else {
            throw ProviderError.invalidBaseURL
        }

        let origin: URL
        switch draft.providerKind {
        case .pipio:
            origin = try ProviderURLNormalizer.pipio(from: inputURL).origin
        case .deepseek:
            origin = try ProviderURLNormalizer.secureOrigin(from: inputURL)
        case .workbuddy2api:
            origin = try ProviderURLNormalizer.workbuddyOrigin(from: inputURL)
        case .custom:
            throw ProviderError.unsupportedProvider
        }

        let sortOrder = (try repository.fetchAccounts().map(\.sortOrder).max() ?? -1) + 1
        return AccountConfiguration(
            displayName: name,
            providerKind: draft.providerKind,
            siteOrigin: origin,
            isEnabled: true,
            lowBalanceThreshold: draft.providerKind == .workbuddy2api ? nil : draft.lowBalanceThreshold,
            sortOrder: sortOrder
        )
    }

    public func updateAccount(
        accountID: UUID,
        displayName: String,
        lowBalanceThreshold: Decimal?,
        replacementCredential: ProviderCredential? = nil,
        replacementBaseURL: String? = nil,
        manualUSDToCNY: ManualExchangeRateUpdate = .unchanged,
        deepSeekUserTokenUpdate: OptionalStringUpdate = .unchanged
    ) async throws {
        guard var account = try repository.account(id: accountID) else { return }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AccountServiceError.missingRequiredFields(["账号显示名称"]) }

        if case let .set(value) = manualUSDToCNY {
            if let value, !USDToCNYRate.isValid(value) {
                throw AccountServiceError.invalidExchangeRate
            }
            account.manualUSDToCNY = value
        }

        let tokenUpdateApplies = account.providerKind == .deepseek && {
            if case .set = deepSeekUserTokenUpdate { return true }
            return false
        }()
        let credentialNeedsRead = replacementCredential != nil || tokenUpdateApplies || replacementBaseURL != nil
        let previousCredential: ProviderCredential?
        if credentialNeedsRead {
            do {
                previousCredential = try await credentialStore.read(reference: account.credentialReference)
            } catch CredentialStoreError.notFound {
                previousCredential = nil
            }
        } else {
            previousCredential = nil
        }

        if let replacementBaseURL {
            guard account.providerKind == .workbuddy2api,
                  let url = URL(string: replacementBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw ProviderError.invalidBaseURL
            }
            account.siteOrigin = try ProviderURLNormalizer.workbuddyOrigin(from: url)
        }

        var effectiveCredential = previousCredential
        if let replacementCredential {
            let preservedDeepSeekToken: String?
            if account.providerKind == .deepseek, previousCredential != nil {
                preservedDeepSeekToken = previousCredential?.deepSeekUserToken
            } else {
                preservedDeepSeekToken = replacementCredential.deepSeekUserToken
            }
            effectiveCredential = ProviderCredential(
                secret: replacementCredential.secret,
                pipioUserID: replacementCredential.pipioUserID,
                deepSeekUserToken: preservedDeepSeekToken
            )
        }
        if account.providerKind == .deepseek,
           case let .set(value) = deepSeekUserTokenUpdate,
           let existing = effectiveCredential {
            let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            effectiveCredential = ProviderCredential(
                secret: existing.secret,
                pipioUserID: existing.pipioUserID,
                deepSeekUserToken: normalized.flatMap { $0.isEmpty ? nil : $0 }
            )
        }

        let credentialChanged = effectiveCredential != nil && effectiveCredential != previousCredential
        if credentialNeedsRead || replacementBaseURL != nil {
            guard let credential = effectiveCredential else { throw CredentialStoreError.notFound }
            let adapter = try adapters.adapter(for: account.providerKind)
            let rate = try await adapter.fetchAccountRate(for: account, credential: credential)
            try await adapter.validateAccount(account, credential: credential)
            if credentialChanged {
                try await credentialStore.save(credential, reference: account.credentialReference)
            }
            if rate.accountID == account.id { await rateService.seed(rate) }
        }

        account.displayName = name
        account.lowBalanceThreshold = account.providerKind == .workbuddy2api ? nil : lowBalanceThreshold
        account.updatedAt = nextUpdateDate(after: account.updatedAt)
        do {
            try repository.upsertAccount(account)
        } catch {
            if credentialChanged {
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

    public func performSubAccountAction(parentID: UUID, externalID: String, action: ProviderSubAccountAction) async throws {
        guard let account = try repository.account(id: parentID), account.providerKind == .workbuddy2api else {
            throw ProviderError.subAccountNotFound
        }
        let credential = try await credentialStore.read(reference: account.credentialReference)
        let adapter = try adapters.adapter(for: .workbuddy2api)
        try await adapter.performSubAccountAction(action, for: account, credential: credential, externalID: externalID)
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
    case missingRequiredFields([String])
    case credentialRollbackFailed
    case invalidExchangeRate

    public var errorDescription: String? {
        switch self {
        case .missingRequiredFields(let fields):
            return "请填写：" + fields.joined(separator: "、") + "。"
        case .credentialRollbackFailed:
            return "账户保存失败，且无法恢复本机凭据。请检查本地存储后重新录入凭据。"
        case .invalidExchangeRate:
            return "美元/人民币汇率必须是大于 0 的有效数字（例如 7.30）；留空使用站点汇率。"
        }
    }
}
