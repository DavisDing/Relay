import Foundation

enum AccountFeedbackChecks {
    @MainActor static func run() async throws {
        func verify(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "AccountFeedbackChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let repository = InMemoryLocalRepository()
        // An empty registry proves validation runs before selecting/calling an adapter.
        let service = AccountService(repository: repository, credentialStore: InMemoryCredentialStore(),
                                     adapters: ProviderAdapterRegistry(adapters: []))
        let cases: [(AccountDraft, [String])] = [
            (AccountDraft(displayName: " \n", providerKind: .pipio, baseURL: " ", credential: ProviderCredential(secret: "\t")),
             ["账号显示名称", "站点地址", "Pipio 用户 ID", "Pipio 系统令牌"]),
            (AccountDraft(displayName: "", providerKind: .pipio, baseURL: "https://example.invalid", credential: ProviderCredential(secret: "fixture", pipioUserID: "1")),
             ["账号显示名称"]),
            (AccountDraft(displayName: "Fixture", providerKind: .pipio, baseURL: "https://example.invalid", credential: ProviderCredential(secret: "")),
             ["Pipio 用户 ID", "Pipio 系统令牌"]),
            (AccountDraft(displayName: "Fixture", providerKind: .deepseek, baseURL: "https://api.deepseek.com", credential: ProviderCredential(secret: "\n")),
             ["DeepSeek API Key"]),
            (AccountDraft(displayName: "Fixture", providerKind: .deepseek, baseURL: "", credential: ProviderCredential(secret: "fixture")),
             ["站点地址"])
        ]
        for (draft, expected) in cases {
            for probe in [true, false] {
                do {
                    if probe { _ = try await service.probe(draft) }
                    else { _ = try await service.addAccount(draft) }
                    throw NSError(domain: "Expected validation failure", code: 1)
                } catch AccountServiceError.missingRequiredFields(let fields) {
                    try verify(fields == expected, "Probe and save list all and only the selected provider's missing fields")
                    try verify(AccountServiceError.missingRequiredFields(fields).errorDescription == "请填写：" + expected.joined(separator: "、") + "。", "Actionable field names")
                }
            }
        }
        let invalidURL = AccountDraft(displayName: "Fixture", providerKind: .pipio, baseURL: "https:/missing-host", credential: ProviderCredential(secret: "fixture", pipioUserID: "1"))
        do {
            _ = try await service.probe(invalidURL)
            throw NSError(domain: "Expected invalid URL", code: 1)
        } catch ProviderError.invalidBaseURL {}
        try verify(try repository.fetchAccounts().isEmpty, "Invalid forms must not create local accounts")

        let counts: [(Int64, String)] = [(-1, "--"), (0, "0"), (999, "999"), (1000, "1K"), (1234, "1.23K"),
            (4700, "4.7K"), (999994, "999.99K"), (999995, "1M"), (1_000_000, "1M"),
            (123_456_789, "123.46M"), (1_234_567_890, "1.23B"), (1_000_000_000_000, "1T"), (Int64.max, "9.22E")]
        for (count, expected) in counts {
            try verify(RelayNumberFormatter.tokens(count) == expected, "Compact token formatting for \(count)")
        }
        let item = ModelUsageItem.items(from: [ModelUsageSummary(modelName: "fixture", tokenCount: 123_456_789, requestCount: 1, cacheHitRate: nil, spend: nil)], currency: .usd)[0]
        try verify(item.tokenCount == 123_456_789 && item.tokens == Int64(123_456_789).formatted(), "Keep exact count for tooltips and accessibility")
        print("PASSED: required fields for probe/save, invalid URL distinction, compact tokens and exact counts")
    }
}
