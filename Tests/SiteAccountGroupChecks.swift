import Foundation

private struct SiteGroupFailure: Error, CustomStringConvertible { let description: String }

@MainActor
enum SiteAccountGroupChecks {
    static func run() throws {
        func check(_ result: @autoclosure () -> Bool, _ message: String) throws {
            if !result() { throw SiteGroupFailure(description: message) }
        }
        func model(_ name: String, _ url: String, kind: ProviderKind = .pipio,
                   hidden: Bool = false, parent: UUID? = nil) -> AccountModel {
            AccountModel(name: name, kind: kind, baseURL: url, balance: 10, currency: .cny,
                         isHidden: hidden, parentAccountID: parent)
        }
        let a = model("Personal", "https://EXAMPLE.invalid:443/api?token=never-show")
        let b = model("Work", "https://example.invalid/v1/")
        let other = model("Other", "https://other.invalid")
        let port = model("Port", "https://example.invalid:8443")
        let http = model("HTTP", "http://example.invalid")
        let adapter = model("Adapter", "https://example.invalid", kind: .deepseek)
        let hidden = model("Hidden", "https://hidden.invalid", hidden: true)
        let all = [a, b, other, port, http, adapter, hidden]
        let groups = SiteAccountGroup.groups(parents: all, dashboardAccounts: all, configurations: [])
        try check(groups.count == 5, "Origins keep host, scheme, non-default ports and adapter scope separate")
        try check(groups[0].accounts.map(\.id) == [a.id, b.id], "Paths and default HTTPS port do not split a site")
        try check(groups[0].address == "example.invalid", "Visible site labels omit queries and credentials")
        try check(SiteAccountGroup.identity(for: model("80", "http://example.invalid:80")) == SiteAccountGroup.identity(for: http),
                  "Default HTTP ports normalize")
        let invalid = model("Invalid", "not a URL")
        let invalid2 = model("Invalid2", "also not a URL")
        try check(SiteAccountGroup.identity(for: invalid) != SiteAccountGroup.identity(for: invalid2), "Malformed origins do not merge")
        let search = SiteAccountGroup.groups(parents: all, dashboardAccounts: all, configurations: [], query: "Work")
        try check(search.count == 1 && search[0].matchingAccounts.map(\.id) == [b.id] && search[0].parents.count == 2,
                  "Search narrows rows but preserves whole-site membership and aggregate IDs")
        let config = AccountConfiguration(id: UUID(uuidString: b.id)!, displayName: b.name, providerKind: .pipio,
            siteOrigin: URL(string: b.baseURL)!, groupName: "Team", isPinned: true)
        let filtered = SiteAccountGroup.groups(parents: all, dashboardAccounts: all, configurations: [config], group: "Team")
        try check(filtered.count == 1 && filtered[0].matchingAccounts.map(\.id) == [b.id] && filtered[0].parents.count == 2,
                  "Organization group filtering preserves whole-site membership")
        let pinned = SiteAccountGroup.groups(parents: [other, a, b], dashboardAccounts: [other, a, b], configurations: [config])
        try check(pinned.first?.accounts.first?.id == b.id, "Pinned accounts order both site groups and their rows")
        let gateway = model("Gateway", "http://localhost:7863", kind: .workbuddy2api)
        let gateway2 = model("Gateway2", "http://localhost:9000", kind: .workbuddy2api)
        let child = model("Child", gateway.baseURL, kind: .workbuddy2api, parent: UUID(uuidString: gateway.id)!)
        var failedChild = child; failedChild.status = .error("连续失败 2 次")
        let gwGroups = SiteAccountGroup.groups(parents: [gateway, gateway2], dashboardAccounts: [failedChild], configurations: [])
        try check(gwGroups.count == 2 && gwGroups[0].accounts.map(\.id) == [child.id] && gwGroups[0].warningCount == 1,
                  "Gateway children stay with their origin and preserve failure status")
        try check(gwGroups[1].accounts.map(\.id) == [gateway2.id], "Gateways with unavailable or empty children remain reachable")

        // Exercise the actual store projection and aggregation used by the home UI.
        let repo = InMemoryLocalRepository()
        var configured = [AccountConfiguration]()
        for (index, url) in ["https://example.invalid", "https://example.invalid/api", "https://other.invalid"].enumerated() {
            let config = AccountConfiguration(displayName: "Account\(index)", providerKind: .pipio, siteOrigin: URL(string: url)!)
            configured.append(config); try repo.upsertAccount(config)
            try repo.upsertSnapshot(ProviderSnapshot(accountID: config.id, balance: MoneyValue(amount: 100, currency: .cny),
                todaySpend: MoneyValue(amount: Decimal(index + 1), currency: .cny), monthSpend: nil, requestCount: nil,
                capabilities: [.balance, .todayUsage], freshness: .fresh,
                rate: AccountRate(accountID: config.id, source: .providerNativeCurrency, nativeCurrency: .cny)))
        }
        let store = RelayStore(repository: repo, credentialStore: InMemoryCredentialStore(),
            adapters: ProviderAdapterRegistry(adapters: []), automaticallyRefresh: false)
        let selectedIDs = Set(configured.prefix(2).map(\.id))
        let total = store.todaySpendTotal(forAccountIDs: selectedIDs)
        try check(total.isComplete && total.value?.amount == 3 && store.todaySpendTotalCNY.value?.amount == 6,
                  "Site totals exclude other sites while the dashboard total remains unchanged")
        let now = Date()
        let providerCalendar = BudgetService.calendar(for: .pipio)
        let yesterday = providerCalendar.date(byAdding: .day, value: -1, to: providerCalendar.startOfDay(for: now))!
        for config in configured {
            try repo.upsertDailyUsage(DailyUsageRecord(accountID: config.id, day: yesterday,
                                                     spend: MoneyValue(amount: 2, currency: .cny)))
        }
        store.updateTemporalPresentation(at: now)
        try check(store.dashboardSpendTrend.count == 7 && store.dashboardSpendTrend[5] == 6
                  && store.dashboardSpendTrend[6] == 6 && store.dashboardSpendTrend[4] == nil,
                  "Home trend uses complete historical totals and the live today total; missing days remain gaps")
        try check(DashboardAggregator.historicalSpendTotal(values: [configured[0].id: MoneyValue(amount: 2, currency: .cny)],
            snapshots: [], expectedAccountIDs: selectedIDs, targetCurrency: .cny, now: now) == nil,
                  "A partially recorded day is never drawn as a complete total")
        let usd = [configured[0].id: MoneyValue(amount: 2, currency: .usd)]
        try check(DashboardAggregator.historicalSpendTotal(values: usd, snapshots: store.snapshots,
            expectedAccountIDs: [configured[0].id], targetCurrency: .cny, now: now) == nil,
                  "Historical sparkline requires usable FX for mixed currencies")
        try check(DashboardAggregator.historicalSpendTotal(values: usd, snapshots: store.snapshots,
            expectedAccountIDs: [configured[0].id], targetCurrency: .cny, now: now,
            manualUSDToCNY: [configured[0].id: 7]) == 14,
                  "Historical sparkline shares the dashboard's per-account manual FX")
        store.setEnabled(accountID: configured[1].id, enabled: false)
        try check(store.todaySpendTotal(forAccountIDs: selectedIDs).value?.amount == 1, "Disabled accounts do not contribute to site totals")
        store.setHidden(accountID: configured[0].id, hidden: true)
        try check(store.todaySpendTotal(forAccountIDs: selectedIDs).value == nil, "Hidden accounts never leak into site totals")
        store.setHidden(accountID: configured[0].id, hidden: false)
        store.setEnabled(accountID: configured[1].id, enabled: true)
        let incompleteID = configured[1].id
        try repo.upsertSnapshot(ProviderSnapshot(accountID: incompleteID, balance: nil, todaySpend: nil,
            monthSpend: nil, requestCount: nil, capabilities: [.balance], freshness: .partial,
            rate: AccountRate(accountID: incompleteID, source: .providerNativeCurrency, nativeCurrency: .cny)))
        store.updateTemporalPresentation(at: Date())
        try check(!store.todaySpendTotal(forAccountIDs: selectedIDs).isComplete,
                  "A missing site member's spend is incomplete, never a fabricated zero or full total")
        try repo.upsertSnapshot(ProviderSnapshot(accountID: incompleteID, balance: nil,
            todaySpend: MoneyValue(amount: 5, currency: .usd), monthSpend: nil, requestCount: nil,
            capabilities: [.todayUsage], freshness: .fresh,
            rate: AccountRate(accountID: incompleteID, source: .providerNativeCurrency, nativeCurrency: .usd)))
        store.updateTemporalPresentation(at: Date())
        try check(!store.todaySpendTotal(forAccountIDs: selectedIDs).isComplete,
                  "Mixed currencies without reliable FX never form a complete site total")
        for (index, host) in ["https://gateway-a.invalid", "https://gateway-b.invalid"].enumerated() {
            let config = AccountConfiguration(displayName: "Gateway \(index)", providerKind: .workbuddy2api,
                siteOrigin: URL(string: host)!)
            try repo.upsertAccount(config)
            let child = ProviderSubAccountSnapshot(parentAccountID: config.id, externalID: "child",
                displayName: "Gateway child", availablePoints: index == 0 ? 12 : nil)
            try repo.upsertSnapshot(ProviderSnapshot(accountID: config.id, balance: nil, todaySpend: nil,
                monthSpend: nil, requestCount: nil, capabilities: [.creditBalance], freshness: .fresh,
                rate: AccountRate(accountID: config.id, source: .providerNativeCurrency, nativeCurrency: .cny), subAccounts: [child]))
            if index == 0 {
                store.updateTemporalPresentation(at: Date())
                try check(store.creditTotal(accountIDs: [config.id]).value == 12,
                          "Credit totals are scoped to that site's gateway IDs")
            } else {
                store.updateTemporalPresentation(at: Date())
                try check(!store.creditTotal(accountIDs: [config.id]).isComplete && store.creditTotal().value == nil,
                          "An unavailable gateway prevents a complete credit total")
            }
        }
        print("PASS: site identity, filtering, gateway visibility, ordering and site totals")
    }
}
