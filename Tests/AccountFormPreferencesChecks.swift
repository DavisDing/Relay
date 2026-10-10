import Foundation

private struct FormPreferencesAdapter: ProviderAdapter {
    var kind: ProviderKind { .pipio }
    func fetchAccountRate(for account: AccountConfiguration, credential: ProviderCredential) async throws -> AccountRate {
        AccountRate(accountID: account.id, source: .providerNativeCurrency, nativeCurrency: .cny)
    }
    func validateAccount(_ account: AccountConfiguration, credential: ProviderCredential) async throws {}
    func fetchSnapshot(for account: AccountConfiguration, credential: ProviderCredential, rate: AccountRate,
                       now: Date, calendar: Calendar) async throws -> ProviderSnapshot {
        ProviderSnapshot(accountID: account.id, balance: MoneyValue(amount: 50, currency: .cny),
                         todaySpend: MoneyValue(amount: 2, currency: .cny), monthSpend: MoneyValue(amount: 10, currency: .cny),
                         requestCount: nil, capabilities: [.balance, .monthlyUsage], freshness: .fresh, fetchedAt: now, rate: rate)
    }
}

private enum FormPreferencesFailure: Error { case injected }

@MainActor
private final class FormPreferencesRepository: LocalRepository {
    let underlying = InMemoryLocalRepository()
    var failAccountSave = false
    var writes = 0
    func fetchAccounts() throws -> [AccountConfiguration] { try underlying.fetchAccounts() }
    func account(id: UUID) throws -> AccountConfiguration? { try underlying.account(id: id) }
    func upsertAccount(_ account: AccountConfiguration) throws {
        if failAccountSave { throw FormPreferencesFailure.injected }
        writes += 1
        try underlying.upsertAccount(account)
    }
    func deleteAccount(id: UUID) throws { try underlying.deleteAccount(id: id) }
    func snapshot(accountID: UUID) throws -> ProviderSnapshot? { try underlying.snapshot(accountID: accountID) }
    func upsertSnapshot(_ snapshot: ProviderSnapshot) throws { try underlying.upsertSnapshot(snapshot) }
    func commitRefresh(_ snapshot: ProviderSnapshot, dailyUsage: DailyUsageRecord?) throws { try underlying.commitRefresh(snapshot, dailyUsage: dailyUsage) }
    func dailyUsage(accountID: UUID, limit: Int?) throws -> [DailyUsageRecord] { try underlying.dailyUsage(accountID: accountID, limit: limit) }
    func upsertDailyUsage(_ record: DailyUsageRecord) throws { try underlying.upsertDailyUsage(record) }
    func settings() throws -> RelaySettings { try underlying.settings() }
    func updateSettings(_ settings: RelaySettings) throws { try underlying.updateSettings(settings) }
    func syncData() throws -> RelaySyncData { try underlying.syncData() }
    func mergeSyncData(_ data: RelaySyncData) throws { try underlying.mergeSyncData(data) }
}

@MainActor
enum AccountFormPreferencesChecks {
    static func run() async throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "AccountFormPreferencesChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let repository = FormPreferencesRepository()
        let credentials = InMemoryCredentialStore()
        let service = AccountService(repository: repository, credentialStore: credentials,
                                     adapters: ProviderAdapterRegistry(adapters: [FormPreferencesAdapter()]))
        let secret = ProviderCredential(secret: "fixture-only", pipioUserID: "1")
        let initialBudget = MoneyValue(amount: 100, currency: .cny)
        let draft = AccountDraft(displayName: "Initial", providerKind: .pipio, baseURL: "https://example.invalid",
                                 credential: secret, monthlyBudget: initialBudget, groupName: " production ", isPinned: true)
        let created = try await service.addAccount(draft)
        let stored = try repository.account(id: created.id)!
        try require(stored.monthlyBudget == initialBudget && stored.groupName == "production" && stored.isPinned,
                    "Add form preferences persist alongside account identity")
        let writesBefore = repository.writes
        let editedBudget = MoneyValue(amount: 200, currency: .usd)
        try await service.updateAccount(accountID: created.id, displayName: "Edited", lowBalanceThreshold: 15,
                                        preferences: .set(monthlyBudget: editedBudget, groupName: " research ", isPinned: false))
        let edited = try repository.account(id: created.id)!
        try require(repository.writes == writesBefore + 1 && edited.displayName == "Edited" && edited.lowBalanceThreshold == 15
                    && edited.monthlyBudget == editedBudget && edited.groupName == "research" && !edited.isPinned,
                    "Edit writes all metadata once, with no separate preference transaction")
        let credentialAfterEdit = try await credentials.read(reference: created.credentialReference)
        try require(credentialAfterEdit == secret, "Preferences-only editing retains credentials")
        try await service.updateAccount(accountID: created.id, displayName: "Legacy", lowBalanceThreshold: 18)
        let legacy = try repository.account(id: created.id)!
        try require(legacy.monthlyBudget == editedBudget && legacy.groupName == "research" && !legacy.isPinned,
                    "Default unchanged preserves preferences for legacy edit callers")
        let beforeInvalid = try repository.syncData()
        for preference in [AccountPreferencesUpdate.set(monthlyBudget: MoneyValue(amount: 0, currency: .cny), groupName: "valid", isPinned: true),
                           .set(monthlyBudget: nil, groupName: String(repeating: "a", count: 41), isPinned: true)] {
            do {
                try await service.updateAccount(accountID: created.id, displayName: "Must not save", lowBalanceThreshold: 0,
                                                replacementCredential: ProviderCredential(secret: "replacement", pipioUserID: "2"),
                                                preferences: preference)
                throw NSError(domain: "Expected invalid preferences", code: 1)
            } catch AccountPreferencesError.invalidBudget {} catch AccountPreferencesError.groupTooLong {}
        }
        let afterInvalid = try repository.syncData()
        let credentialAfterInvalid = try await credentials.read(reference: created.credentialReference)
        try require(afterInvalid.hasSameContent(as: beforeInvalid) && credentialAfterInvalid == secret,
                    "Invalid preferences leave all metadata and secrets unchanged")

        repository.failAccountSave = true
        do {
            try await service.updateAccount(accountID: created.id, displayName: "Must roll back", lowBalanceThreshold: 1,
                                            replacementCredential: ProviderCredential(secret: "replacement", pipioUserID: "2"),
                                            preferences: .set(monthlyBudget: nil, groupName: nil, isPinned: true))
            throw NSError(domain: "Expected account save failure", code: 1)
        } catch FormPreferencesFailure.injected {}
        let afterFailure = try repository.syncData()
        let credentialAfterFailure = try await credentials.read(reference: created.credentialReference)
        try require(afterFailure.hasSameContent(as: beforeInvalid) && credentialAfterFailure == secret,
                    "Failed combined account save preserves metadata and rolls back changed credentials")
        repository.failAccountSave = false
        try await service.updateAccount(accountID: created.id, displayName: "Cleared", lowBalanceThreshold: 20,
                                        preferences: .set(monthlyBudget: nil, groupName: "  ", isPinned: false))
        let cleared = try repository.account(id: created.id)!
        try require(cleared.monthlyBudget == nil && cleared.groupName == nil && !cleared.isPinned,
                    "Explicit empty form values clear optional preferences")

        let invalidAddService = AccountService(repository: repository, credentialStore: credentials,
                                              adapters: ProviderAdapterRegistry(adapters: []))
        let invalidDraft = AccountDraft(displayName: "Bad", providerKind: .pipio, baseURL: "https://example.invalid",
                                        credential: secret, monthlyBudget: MoneyValue(amount: -1, currency: .cny))
        for probe in [true, false] {
            do {
                if probe { _ = try await invalidAddService.probe(invalidDraft) }
                else { _ = try await invalidAddService.addAccount(invalidDraft) }
                throw NSError(domain: "Expected preflight validation", code: 1)
            } catch AccountPreferencesError.invalidBudget {}
        }
        try require(try repository.fetchAccounts().count == 1, "Invalid add or probe creates no extra account")
        let gateway = AccountConfiguration(displayName: "Gateway", providerKind: .workbuddy2api,
                                           siteOrigin: URL(string: "http://localhost:7863")!, groupName: "old", isPinned: false)
        try repository.upsertAccount(gateway)
        try await service.updateAccount(accountID: gateway.id, displayName: "Gateway", lowBalanceThreshold: nil,
                                        preferences: .set(monthlyBudget: nil, groupName: "gateway-group", isPinned: true))
        let gatewayEdited = try repository.account(id: gateway.id)!
        try require(gatewayEdited.monthlyBudget == nil && gatewayEdited.groupName == "gateway-group" && gatewayEdited.isPinned,
                    "Gateway supports group and pin without reliable monthly spend")
        do {
            try await service.updateAccount(accountID: gateway.id, displayName: "Gateway", lowBalanceThreshold: nil,
                                            preferences: .set(monthlyBudget: initialBudget, groupName: nil, isPinned: false))
            throw NSError(domain: "Expected unsupported gateway budget", code: 1)
        } catch AccountPreferencesError.unsupportedBudget {}
        print("PASSED: add/edit atomic preferences, validation preservation, unchanged secrets, credential rollback and gateway limits")
    }
}
