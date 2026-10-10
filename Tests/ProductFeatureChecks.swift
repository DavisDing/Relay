import Foundation

private struct ProductFeatureFailure: Error, CustomStringConvertible { let description: String }

@MainActor
enum ProductFeatureChecks {
    static func run() throws {
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw ProductFeatureFailure(description: message) }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12))!
        let previousMonth = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30))!
        let id = UUID()
        let budget = MoneyValue(amount: 100, currency: .cny)
        func snapshot(_ amount: Decimal?, currency: Currency = .cny, date: Date = now,
                      freshness: DataFreshness = .fresh, accountID: UUID = id) -> ProviderSnapshot {
            ProviderSnapshot(accountID: accountID, balance: nil, todaySpend: nil,
                             monthSpend: amount.map { MoneyValue(amount: $0, currency: currency) }, requestCount: nil,
                             capabilities: [.monthlyUsage], freshness: freshness, fetchedAt: date,
                             rate: AccountRate(accountID: accountID, source: .providerNativeCurrency,
                                               nativeCurrency: currency, fetchedAt: date))
        }
        func alert(_ snapshot: ProviderSnapshot?, state: BudgetAlertState = BudgetAlertState(), budget: MoneyValue? = budget) -> BudgetAlertEvent? {
            BudgetService.nextAlert(accountID: id, accountName: "fixture", isEnabled: true,
                                    budget: budget, snapshot: snapshot, state: state, now: now, calendar: calendar)
        }
        try check(alert(snapshot(79)) == nil, "Below 80 percent sends no budget alert")
        let eighty = alert(snapshot(80))!
        try check(eighty.key.threshold == .approaching, "Inclusive 80-percent threshold")
        var state = BudgetAlertState()
        state.markDelivered(eighty)
        let restored = try JSONDecoder().decode(BudgetAlertState.self, from: JSONEncoder().encode(state))
        try check(alert(snapshot(90), state: restored) == nil, "Persisted delivery state survives restart")
        let full = alert(snapshot(100), state: restored)!
        try check(full.key.threshold == .exceeded, "80-percent delivery does not suppress 100 percent")
        state.markDelivered(full)
        try check(alert(snapshot(150), state: state) == nil && alert(snapshot(90), state: state) == nil,
                  "100 percent also suppresses obsolete 80-percent reminder")
        try check(alert(snapshot(150))?.key.threshold == .exceeded, "First crossing above 100 sends only strongest alert")
        try check(alert(snapshot(nil)) == nil && alert(snapshot(150, currency: .usd)) == nil,
                  "Unknown month spend and currency mismatch never produce budget alerts")
        try check(alert(snapshot(150, date: previousMonth)) == nil, "Previous-month cache is not current budget spend")
        try check(alert(snapshot(150, freshness: .partial)) == nil && alert(snapshot(150, freshness: .stale)) == nil,
                  "Partial and stale snapshots do not trigger alerts")
        try check(alert(snapshot(150, accountID: UUID())) == nil, "An account never reads another account's monthly spend")
        try check(alert(snapshot(100), state: state, budget: MoneyValue(amount: 50, currency: .cny)) != nil,
                  "Explicit budget change has separate notification threshold state")
        let november = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        try check(BudgetService.nextAlert(accountID: id, accountName: "fixture", isEnabled: true, budget: budget,
                                         snapshot: snapshot(100, date: november), state: state, now: november,
                                         calendar: calendar) != nil, "New month resets alert eligibility")
        try check(BudgetService.nextAlert(accountID: id, accountName: "fixture", isEnabled: false, budget: budget,
                                         snapshot: snapshot(100), state: state, now: now, calendar: calendar) == nil,
                  "Disabled accounts do not notify")
        try check(try BudgetService.parseBudget("  ", currency: .cny) == nil, "Empty budget disables")
        for text in ["0", "-1", "1x", "1e3", "NaN"] {
            do { _ = try BudgetService.parseBudget(text, currency: .cny); throw ProductFeatureFailure(description: "Invalid budget accepted: \(text)") }
            catch BudgetInputError.invalidAmount { }
        }
        try check(try BudgetService.parseBudget("10.50", currency: .usd) == MoneyValue(amount: Decimal(string: "10.5")!, currency: .usd),
                  "Budget amount and explicit currency preserved")
        let providerBoundary = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 18))!
        try check(BudgetService.monthKey(at: providerBoundary, calendar: BudgetService.calendar(for: .deepseek)) == "2026-11"
                  && BudgetService.monthKey(at: providerBoundary, calendar: calendar) == "2026-10",
                  "DeepSeek month boundary uses fixed GMT+8 rather than machine calendar")
        try check(BudgetService.calendar(for: .deepseek).timeZone.secondsFromGMT() == 28_800,
                  "DeepSeek budget month follows GMT+8")

        let normal = AccountConfiguration(displayName: "Production", providerKind: .pipio,
                                          siteOrigin: URL(string: "https://example.invalid")!, groupName: " work ", sortOrder: 0)
        let pinned = AccountConfiguration(displayName: "Research", providerKind: .pipio,
                                          siteOrigin: URL(string: "https://example.invalid")!, groupName: "lab", isPinned: true, sortOrder: 1)
        let normalModel = AccountModel(id: normal.id.uuidString, name: normal.displayName, kind: .pipio, baseURL: "https://example.invalid", balance: 12, currency: .cny)
        let pinnedModel = AccountModel(id: pinned.id.uuidString, name: pinned.displayName, kind: .pipio, baseURL: "https://example.invalid", balance: 8, currency: .cny)
        let configurations = [normal, pinned]
        try check(AccountOrganizationService.sorted([normalModel, pinnedModel], configurations: configurations).first?.id == pinnedModel.id,
                  "Pin order outranks saved account order")
        try check(AccountOrganizationService.groups(in: configurations) == ["lab", "work"], "Groups are normalized and unique")
        try check(AccountOrganizationService.filtered([normalModel, pinnedModel], configurations: configurations, query: "PROD", group: "work").map(\.id) == [normalModel.id],
                  "Case-insensitive search composes with exact normalized group filtering")
        let child = AccountModel(id: "gateway:child", name: "child", kind: .workbuddy2api, baseURL: "https://example.invalid", balance: nil, currency: .cny, parentAccountID: pinned.id)
        try check(AccountOrganizationService.matches(child, configurations: configurations, query: "Research", group: "lab"),
                  "Gateway children inherit parent's group and searchable identity")
        try check(AccountOrganizationService.filtered([normalModel, pinnedModel], configurations: configurations, query: "absent", group: nil).isEmpty,
                  "No matching account stays an empty result rather than inventing data")

        func model(_ name: String, cost: Decimal?, tokens: Int64?, currency: Currency = .cny) -> ModelUsageItem {
            ModelUsageItem(id: name, modelName: name, tokens: tokens.map(String.init) ?? "--", cost: cost,
                           currency: currency, percentage: nil, tokenCount: tokens)
        }
        let models = [model("paid", cost: 10, tokens: 2_000_000), model("free", cost: 0, tokens: 100),
                      model("unknown", cost: nil, tokens: nil)]
        let incomplete = ModelAnalysisService.analyze(models)
        try check(incomplete.rows.map(\.id) == ["paid", "free", "unknown"], "Free and unknown models preserved in stable spend order")
        try check(incomplete.rows.allSatisfy { $0.spendShare == nil }, "Unknown spend suppresses complete percentage")
        try check(incomplete.rows[0].costPerMillionTokens == MoneyValue(amount: 5, currency: .cny), "Per-million aggregate token cost")
        try check(incomplete.rows[1].costPerMillionTokens?.amount == 0 && incomplete.rows[2].costPerMillionTokens == nil,
                  "Free known usage has zero unit cost while missing usage remains unknown")
        let all = (1...6).map { model("m\($0)", cost: Decimal($0), tokens: Int64($0)) }
        let top = ModelAnalysisService.analyze(all, topFive: true)
        try check(top.rows.count == 5 && top.rows[0].item.modelName == "m6" && top.rows[0].spendShare == Decimal(6) / Decimal(21),
                  "Top-five shares retain the whole fetched-data denominator")
        try check(ModelAnalysisService.analyze(all, sort: .tokens).rows.first?.item.modelName == "m6", "Token sort uses full numeric count")
        let mixed = ModelAnalysisService.analyze([model("usd", cost: 20, tokens: 1, currency: .usd), model("cny", cost: 10, tokens: 1)])
        try check(mixed.hasMixedCurrencies && mixed.rows.allSatisfy { $0.spendShare == nil }, "Native currencies never manufacture cross-currency shares")
        try check(ModelAnalysisService.analyze([model("zero", cost: 0, tokens: 0)]).rows[0].costPerMillionTokens == nil,
                  "Zero-token denominator has unknown unit cost")
        print("PASSED: budget thresholds/persisted dedup/month/currency, pin/group/search and model share/unit-cost integrity")
    }
}
