import Foundation

private struct PipioCheckFailure: Error { let message: String }
private func verify(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PipioCheckFailure(message: message) }
}

private actor DashboardFixtureClient: HTTPClient {
    let dashboard: Data
    let status: String
    let statQuota: Int
    let rejectDashboard: Bool
    private var paths: [String] = []
    init(dashboard: Data, status: String = #"{"success":true,"data":{"quota_per_unit":500000,"credit_currency":"USD","usd_exchange_rate":7.3}}"#, rejectDashboard: Bool = false, statQuota: Int = 6435000) {
        self.statQuota = statQuota
        self.dashboard = dashboard
        self.status = status
        self.rejectDashboard = rejectDashboard
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        paths.append(url.path)
        let data: Data
        switch url.path {
        case "/api/status": data = Data(status.utf8)
        case "/api/user/self": data = Data(#"{"success":true,"data":{"quota":50000000,"request_count":10}}"#.utf8)
        case "/api/log/self/stat": data = Data("{\"success\":true,\"data\":{\"quota\":\(statQuota)}}".utf8)
        case "/api/data/self":
            try verify(request.value(forHTTPHeaderField: "Pipio-User") == "1", "separate user ID header")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            try verify(Set(query.map(\.name)) == ["start_timestamp", "end_timestamp"], "dashboard range, no log pagination")
            if rejectDashboard { throw ProviderError.forbidden }
            data = dashboard
        default: throw PipioCheckFailure(message: "unexpected endpoint " + url.path)
        }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func count(_ path: String) -> Int { paths.filter { $0 == path }.count }
}

enum PipioDashboardContractChecks {
    @MainActor static func run() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date()
        let start = calendar.startOfDay(for: now)
        let timestamp = Int64(start.timeIntervalSince1970)
        let range = DateInterval(start: start, end: now)
        func row(_ name: String, quota: Int, tokens: Int, read: Int = 250, eligible: Int = 1000) -> [String: Any] {
            ["created_at": timestamp, "model_name": name, "quota": quota, "count": 1,
             "token_used": tokens, "input_tokens": eligible - read, "output_tokens": 200,
             "cache_read_tokens": read, "cache_write_tokens": 0,
             "token_breakdown_count": 1, "token_breakdown_request_count": 1,
             "token_breakdown_tracked_token_used": tokens, "cache_metrics_request_count": 1,
             "cache_eligible_input_tokens": eligible]
        }
        func envelope(_ rows: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["success": true, "data": rows])
        }
        // Synthetic fixtures, not captured account data: repeated buckets must sum.
        var rows = [row("fixture-terra", quota: 3010000, tokens: 1200),
                    row("fixture-terra", quota: 3425000, tokens: 3500, read: 1500, eligible: 3000)]
        rows += (1...3).map { row("fixture-model-\($0)", quota: 500000, tokens: 1200) }
        rows.append(row("fixture-free-model", quota: 0, tokens: 1200))
        var yesterday = row("outside-range", quota: 9000000, tokens: 1200)
        yesterday["created_at"] = timestamp - 1
        rows.append(yesterday)
        let data = try envelope(rows)
        let models = try PipioDashboardParser.models(from: data, range: range, quotaPerUnit: 500000, currency: .usd)
        try verify(models.count == 5, "all five active models, including free model")
        let terra = models.first { $0.modelName == "fixture-terra" }!
        try verify(terra.spend?.amount == Decimal(string: "12.87"), "sum all dashboard buckets, not 6.02 partial logs")
        try verify(terra.tokenCount == 4700, "dashboard token_used sum")
        try verify(terra.cacheHitRate == Decimal(string: "0.4375"), "weighted eligible-input cache share")
        try verify(ModelUsageItem.items(from: models, currency: .usd).count == 5, "presentation retains all models")
        var incomplete = row("incomplete", quota: 0, tokens: 1200)
        incomplete.removeValue(forKey: "token_used")
        incomplete.removeValue(forKey: "quota")
        incomplete.removeValue(forKey: "input_tokens")
        let unknown = try PipioDashboardParser.models(from: envelope([incomplete]), range: range, quotaPerUnit: 500000, currency: .usd)
        try verify(unknown.first?.tokenCount == nil && unknown.first?.cacheHitRate == nil, "missing metrics stay unknown")
        let unknownItems = ModelUsageItem.items(from: unknown, currency: .usd)
        try verify(unknownItems.count == 1 && unknownItems[0].cost == nil, "missing spend must not delete model")
        let free = try PipioDashboardParser.models(from: envelope([row("free", quota: 0, tokens: 1200)]), range: range, quotaPerUnit: 500000, currency: .usd)
        try verify(ModelUsageItem.items(from: free, currency: .usd).count == 1, "all-free day still has models")
        for key in ["token_breakdown_tracked_token_used", "cache_metrics_request_count", "token_breakdown_count"] {
            var partial = row("partial", quota: 1, tokens: 1200)
            partial[key] = 0
            let parsed = try PipioDashboardParser.models(from: envelope([partial]), range: range, quotaPerUnit: 500000, currency: .usd)
            try verify(parsed[0].cacheHitRate == Decimal(string: "0.25"), "N/A coverage falls back to cache reads / total inputs")
        }
        // No raw response or credentials: exercise total-token and N/A fallbacks with synthetic counts.
        func parseRows(_ rows: [[String: Any]]) throws -> [ModelUsageSummary] {
            try PipioDashboardParser.models(from: envelope(rows), range: range, quotaPerUnit: 500000, currency: .usd)
        }
        var fallback = row("fallback", quota: 1, tokens: 1200)
        fallback.removeValue(forKey: "token_used")
        fallback.removeValue(forKey: "cache_eligible_input_tokens")
        let derived = try parseRows([fallback])
        try verify(derived[0].tokenCount == 1200, "derive missing total from ordinary input + read + write + output")
        try verify(derived[0].cacheHitRate == Decimal(string: "0.25"), "cache fallback includes reads in total input")
        var secondBucket = fallback
        secondBucket["input_tokens"] = 1500
        secondBucket["cache_read_tokens"] = 1500
        let weighted = try parseRows([fallback, secondBucket])
        try verify(weighted[0].tokenCount == 4400, "derive then sum token counts across time buckets")
        try verify(weighted[0].cacheHitRate == Decimal(string: "0.4375"), "fallback uses sum(read) / sum(all input components), not average percentages")
        let mixed = try parseRows([fallback, row("fallback", quota: 1, tokens: 9000)])
        try verify(mixed[0].tokenCount == 10200, "prefer provider total in buckets where present")
        var authoritative = row("original", quota: 1, tokens: 9000, read: 500, eligible: 2000)
        authoritative["input_tokens"] = 4000
        let preferred = try parseRows([authoritative])
        try verify(preferred[0].tokenCount == 9000, "don't replace explicit provider token total with a different breakdown")
        try verify(preferred[0].cacheHitRate == Decimal(string: "0.25"), "retain existing valid provider cache contract before fallback")
        // Mixed five-model response: one provider ratio plus four independent fallbacks.
        // Interleave repeated buckets so neither grouping nor display order can hide a model.
        var multipleModels = [authoritative]
        var expectedRates: [String: Decimal] = ["original": Decimal(string: "0.25")!]
        for index in 1...4 {
            let name = "fallback-model-\(index)"
            var first = fallback
            first["model_name"] = name
            first["input_tokens"] = 1000
            first["cache_read_tokens"] = index * 100
            var second = first
            second["input_tokens"] = 3000
            second["cache_read_tokens"] = index * 300
            multipleModels.insert(first, at: 0)
            multipleModels.append(second)
            expectedRates[name] = Decimal(index * 400) / Decimal(4000 + index * 400)
        }
        let mixedModels = try parseRows(multipleModels)
        try verify(mixedModels.count == 5, "one provider plus four fallback models all survive grouping")
        for model in mixedModels {
            try verify(model.cacheHitRate == expectedRates[model.modelName], "each model independently resolves its weighted cache share")
        }
        let mixedItems = ModelUsageItem.items(from: mixedModels, currency: .usd)
        try verify(mixedItems.count == 5 && mixedItems.allSatisfy { $0.cacheHitRate == expectedRates[$0.modelName] },
                   "all five independent ratios reach the model table")
        var incompleteBucket = fallback
        incompleteBucket["model_name"] = "fallback-model-4"
        incompleteBucket.removeValue(forKey: "cache_read_tokens")
        let isolated = try parseRows(multipleModels + [incompleteBucket])
        try verify(isolated.count == 5, "incomplete cache data does not remove model rows")
        for model in isolated {
            let expected = model.modelName == "fallback-model-4" ? nil : expectedRates[model.modelName]
            try verify(model.cacheHitRate == expected, "a missing bucket affects only its own model, not sibling fallbacks")
        }
        for (input, read, expected) in [(1000, 0, Decimal.zero as Decimal?),
                                        (1000, 1000, Decimal(string: "0.5")), (0, 0, nil),
                                        (0, 1000, Decimal(1)),
                                        (1000, 1001, Decimal(1001) / Decimal(2001)), (-1, 0, nil), (1000, -1, nil)] {
            var invalid = fallback
            invalid["input_tokens"] = input
            invalid["cache_read_tokens"] = read
            let parsed = try parseRows([invalid])
            try verify(parsed[0].cacheHitRate == expected, "cache fallback accepts reads above ordinary input, guards zero denominator and negative counts")
        }
        for key in ["input_tokens", "cache_read_tokens", "cache_write_tokens"] {
            var missing = fallback
            missing.removeValue(forKey: key)
            let parsed = try parseRows([fallback, missing])
            try verify(parsed[0].cacheHitRate == nil && parsed[0].tokenCount == nil,
                       "a missing input component must not silently become zero or be excluded")
        }
        var withWrites = fallback
        withWrites["cache_write_tokens"] = 1000
        let written = try parseRows([withWrites])
        try verify(written[0].tokenCount == 2200 && written[0].cacheHitRate == Decimal(string: "0.125"),
                   "cache writes contribute to total input and total tokens, not the hit numerator")
        withWrites["cache_write_tokens"] = -1
        let negativeWrite = try parseRows([withWrites])
        try verify(negativeWrite[0].tokenCount == nil && negativeWrite[0].cacheHitRate == nil,
                   "negative writes cannot produce derived totals or ratios")
        var zeroOrdinaryInput = fallback
        zeroOrdinaryInput["input_tokens"] = 0
        let allCached = try parseRows([zeroOrdinaryInput])
        try verify(allCached[0].tokenCount == 450 && allCached[0].cacheHitRate == 1,
                   "all-cached input is valid even with zero ordinary input")

        // Transcribed from the user's website table, NOT a captured API response.
        // Partial coverage is intentional: provider token_used stays authoritative while
        // the requested fallback ratio describes the available token breakdown only.
        let website: [(name: String, calls: Int, total: Int, covered: Int, expected: Int,
                       input: Int, output: Int, read: Int, cents: Int, percent: String)] = [
            ("gpt-5.6-terra", 417, 31_117_317, 411, 413, 3_665_337, 240_525, 27_036_288, 1287, "88.06%"),
            ("gpt-6-astra", 259, 19_015_989, 258, 259, 957_313, 98_099, 17_947_520, 2622, "94.94%"),
            ("deepseek-v4.1-flash", 86, 7_405_441, 82, 86, 6_577_120, 6_973, 0, 9, "0.00%"),
            ("codex-auto-review", 82, 2_987_985, 79, 82, 697_691, 28_790, 2_261_504, 439, "76.42%"),
            ("gpt-5.6-sol", 28, 2_484_821, 28, 28, 185_677, 5_256, 2_293_888, 179, "92.51%")
        ]
        let websiteRows: [[String: Any]] = website.map { sample in
            var point = row(sample.name, quota: sample.cents * 5000, tokens: sample.total,
                            read: sample.read, eligible: sample.input + sample.read)
            point["count"] = sample.calls
            point["input_tokens"] = sample.input
            point["output_tokens"] = sample.output
            point["token_breakdown_count"] = sample.covered
            point["token_breakdown_request_count"] = sample.expected
            point["token_breakdown_tracked_token_used"] = sample.input + sample.output + sample.read
            // The table doesn't expose these API fields. Simulate a valid contract only
            // for sol (its raw ratio rounds to the website's 92.5%); others exercise N/A.
            if sample.name == "gpt-5.6-sol" {
                point["cache_metrics_request_count"] = sample.covered
            } else {
                point.removeValue(forKey: "cache_metrics_request_count")
                point.removeValue(forKey: "cache_eligible_input_tokens")
            }
            return point
        }
        let websiteModels = try parseRows(websiteRows)
        try verify(websiteModels.map(\.modelName) == ["gpt-6-astra", "gpt-5.6-terra", "codex-auto-review", "gpt-5.6-sol", "deepseek-v4.1-flash"],
                   "website models remain sorted by spend, not tokens or cache rate")
        for sample in website {
            let model = websiteModels.first { $0.modelName == sample.name }!
            try verify(model.tokenCount == Int64(sample.total) && model.requestCount == Int64(sample.calls),
                       "website totals and request counts survive partial breakdown coverage")
            try verify(model.spend?.amount == Decimal(sample.cents) / 100,
                       "cache fallback never changes model spend")
            let expectedRate = Decimal(sample.read) / Decimal(sample.input + sample.read)
            try verify(model.cacheHitRate == expectedRate, "every website model has its own cache ratio")
            try verify(model.cacheHitRate.map(RelayNumberFormatter.percent) == sample.percent,
                       "website fallback percentages render correctly, including explicit zero")
        }
        let websiteItems = ModelUsageItem.items(from: websiteModels, currency: .usd)
        try verify(websiteItems.count == 5 && websiteItems.allSatisfy { $0.cacheHitRate != nil },
                   "all five website cache ratios reach presentation")
        let websiteUsage = try PipioDashboardParser.usage(from: envelope(websiteRows), range: range,
                                                         quotaPerUnit: 500000, currency: .usd)
        try verify(websiteUsage.spend?.amount == Decimal(string: "45.36"),
                   "website table amount remains independent of corrected token calculations")

        var missingOutput = fallback
        missingOutput.removeValue(forKey: "output_tokens")
        let partialTotal = try parseRows([fallback, missingOutput])
        try verify(partialTotal[0].tokenCount == nil, "partial totals remain unknown when input/output are incomplete")
        var negativeTotal = fallback
        negativeTotal["token_used"] = -1
        let negative = try parseRows([negativeTotal])
        try verify(negative[0].tokenCount == nil, "invalid explicit totals aren't silently replaced")
        var overflow = fallback
        overflow["input_tokens"] = Int64.max
        overflow["output_tokens"] = 1
        do {
            _ = try parseRows([overflow])
            throw PipioCheckFailure(message: "token fallback overflow must fail safely")
        } catch ProviderError.incompatibleResponse {}
        var inputOverflow = fallback
        inputOverflow["token_used"] = 1200
        inputOverflow["input_tokens"] = Int64.max
        do {
            _ = try parseRows([inputOverflow])
            throw PipioCheckFailure(message: "cache denominator overflow must fail safely even with provider total")
        } catch ProviderError.incompatibleResponse {}
        var unknownCost = row("unknown-cost", quota: 1, tokens: 999999)
        unknownCost.removeValue(forKey: "quota")
        let ordered = try parseRows([row("cheap", quota: 1, tokens: 900000),
                                    row("expensive", quota: 100, tokens: 10),
                                    row("free", quota: 0, tokens: 1000000), unknownCost,
                                    row("a-tie", quota: 100, tokens: 5)])
        let expectedOrder = ["a-tie", "expensive", "cheap", "free", "unknown-cost"]
        try verify(ordered.map(\.modelName) == expectedOrder, "spend descending, stable name ties, free before unknown")
        let presented = ModelUsageItem.items(from: Array(ordered.reversed()), currency: .usd)
        try verify(presented.map(\.modelName) == expectedOrder, "presentation reorders pre-existing cached snapshots too")
        try verify(ModelUsageItem.items(from: derived, currency: .usd)[0].tokens != "--", "derived token totals reach presentation")
        let empty = try PipioDashboardParser.models(from: envelope([]), range: range, quotaPerUnit: 500000, currency: .usd)
        try verify(empty.isEmpty, "valid empty dashboard")
        for invalid in [#"{"success":false,"data":[]}"#, #"{"success":true,"data":{"items":[]}}"#] {
            do {
                _ = try PipioDashboardParser.models(from: Data(invalid.utf8), range: range, quotaPerUnit: 500000, currency: .usd)
                throw PipioCheckFailure(message: "invalid dashboard should fail")
            } catch is ProviderError { }
        }
        let client = DashboardFixtureClient(dashboard: data)
        let adapter = PipioAdapter(client: client)
        let account = AccountConfiguration(displayName: "Fixture", providerKind: .pipio, siteOrigin: URL(string: "https://example.invalid")!)
        let credential = ProviderCredential(secret: "fixture-not-a-real-token", pipioUserID: "1")
        let rate = try await adapter.fetchAccountRate(for: account, credential: credential)
        try verify(rate.conversionToCNY == Decimal(string: "7.3"), "published exchange rate is retained")
        let snapshot = try await adapter.fetchSnapshot(for: account, credential: credential, rate: rate, now: now, calendar: calendar)
        try verify(snapshot.modelUsages?.count == 5, "adapter integrates dashboard models")
        let total = DashboardAggregator.balanceTotal(snapshots: [snapshot], targetCurrency: .cny, now: now)
        try verify(total.isComplete && total.value?.amount == 730, "home and menu balance converts to CNY")
        let today = DashboardAggregator.todaySpendTotal(snapshots: [snapshot], targetCurrency: .cny, now: now, calendar: calendar)
        try verify(today.isComplete && today.value?.amount == Decimal(string: "115.851"), "today CNY total includes all dashboard model quotas")
        // Reproduce the reported discrepancy without real account data: logs say 35.15,
        // while dashboard model quotas sum to 34.45. Only today's source changes.
        let mismatchClient = DashboardFixtureClient(dashboard: try envelope([
            row("model-a", quota: 10000000, tokens: 1000),
            row("model-b", quota: 7225000, tokens: 2000)
        ]), statQuota: 17575000)
        let mismatchAdapter = PipioAdapter(client: mismatchClient)
        let corrected = try await mismatchAdapter.fetchSnapshot(for: account, credential: credential, rate: rate, now: now, calendar: calendar)
        try verify(corrected.todaySpend?.amount == Decimal(string: "34.45"), "today follows dashboard, not the 35.15 log statistic")
        try verify(corrected.modelUsages?.compactMap { $0.spend?.amount }.reduce(.zero, +) == corrected.todaySpend?.amount,
            "today and models are derived from the same response")
        try verify(corrected.balance?.amount == 100 && corrected.monthSpend?.amount == Decimal(string: "35.15"), "balance/month retain original sources")
        let dashboardCalls = await mismatchClient.count("/api/data/self")
        let statCalls = await mismatchClient.count("/api/log/self/stat")
        try verify(dashboardCalls == 1 && statCalls == 1, "one shared today dashboard request, only month uses stat")
        let history = try await mismatchAdapter.fetchDailyUsage(for: account, credential: credential, rate: rate, endingAt: now, days: 7, calendar: calendar)
        try verify(history.count == 6 && history.allSatisfy { $0.day < start }, "history backfill cannot overwrite today's dashboard snapshot")
        let oneDay = try await mismatchAdapter.fetchDailyUsage(for: account, credential: credential, rate: rate, endingAt: now, days: 1, calendar: calendar)
        try verify(oneDay.isEmpty, "one-day history already covered by snapshot")
        let creationRepository = InMemoryLocalRepository()
        let creationService = AccountService(repository: creationRepository, credentialStore: InMemoryCredentialStore(),
            adapters: ProviderAdapterRegistry(adapters: [mismatchAdapter]), calendar: calendar)
        let created = try await creationService.addAccount(AccountDraft(displayName: "Fixture", providerKind: .pipio,
            baseURL: " https://example.invalid ", credential: credential))
        let createdSnapshot = try creationRepository.snapshot(accountID: created.id)
        let daily = try creationRepository.dailyUsage(accountID: created.id, limit: nil)
        try verify(createdSnapshot?.todaySpend?.amount == Decimal(string: "34.45") && daily.first(where: { $0.day == start })?.spend == createdSnapshot?.todaySpend,
            "account creation preserves corrected today amount after historical backfill")
        let emptyUsage = try PipioDashboardParser.usage(from: envelope([]), range: range, quotaPerUnit: 500000, currency: .usd)
        try verify(emptyUsage.spend?.amount == .zero && emptyUsage.models?.isEmpty == true, "valid empty dashboard is known zero")
        let incompleteUsage = try PipioDashboardParser.usage(from: envelope([rows[0], unknownCost]), range: range, quotaPerUnit: 500000, currency: .usd)
        try verify(incompleteUsage.spend == nil, "one missing model quota makes total unknown")
        let overflowUsage = try PipioDashboardParser.usage(from: envelope([overflow]), range: range, quotaPerUnit: 500000, currency: .usd)
        try verify(overflowUsage.spend != nil && overflowUsage.models == nil, "token overflow cannot discard valid spend")
        let filteredUsage = try PipioDashboardParser.usage(from: data, range: range, quotaPerUnit: 500000, currency: .usd)
        try verify(filteredUsage.spend?.amount == Decimal(string: "15.87"), "out-of-range quotas never leak into today")
        let service = RateService()
        let legacy = AccountRate(accountID: account.id, source: .pipioAccountStatus, nativeCurrency: .usd, quotaPerUnit: 500000, conversionToCNY: nil, fetchedAt: now)
        _ = try await service.resolve(account: account, credential: credential, adapter: adapter, persistedRate: legacy, forceRefresh: false, now: now)
        let calls = await client.count("/api/status")
        try verify(calls == 2, "upgrade repairs unexpired legacy rate without manual action")
        let missingClient = DashboardFixtureClient(dashboard: data, status: #"{"success":true,"data":{"quota_per_unit":500000,"credit_currency":"USD"}}"#, rejectDashboard: true)
        let missingAdapter = PipioAdapter(client: missingClient)
        let missingRate = try await missingAdapter.fetchAccountRate(for: account, credential: credential)
        try verify(missingRate.conversionToCNY == nil, "no hardcoded fallback FX")
        let partial = try await missingAdapter.fetchSnapshot(for: account, credential: credential, rate: missingRate, now: now, calendar: calendar)
        try verify(partial.balance != nil && partial.monthSpend != nil && partial.modelUsages == nil && partial.todaySpend == nil,
            "denied dashboard preserves balance/month but never substitutes a different today-spend source")
        try verify(!partial.capabilities.contains(.todayUsage) && partial.freshness == .partial, "missing dashboard amount is partial, not fresh zero")
        // User FX is account metadata, never an alternative quota divisor.
        var manualAccount = account
        manualAccount.manualUSDToCNY = 8
        let manualRateService = RateService()
        _ = try await manualRateService.resolve(account: manualAccount, credential: credential,
            adapter: missingAdapter, persistedRate: missingRate, forceRefresh: false, now: now)
        let unchangedCalls = await missingClient.count("/api/status")
        try verify(unchangedCalls == 1, "manual FX avoids repeatedly refetching missing site FX before expiry")
        let repository = InMemoryLocalRepository()
        try repository.upsertAccount(manualAccount)
        try repository.upsertSnapshot(partial)
        let credentials = InMemoryCredentialStore()
        try await credentials.save(credential, reference: manualAccount.credentialReference)
        let store = RelayStore(repository: repository, credentialStore: credentials,
            adapters: ProviderAdapterRegistry(adapters: [missingAdapter]), automaticallyRefresh: false)
        await store.refresh(accountID: manualAccount.id, forceRateRefresh: true)
        let refreshed = try repository.snapshot(accountID: manualAccount.id)
        try verify(refreshed?.balance?.amount == 100 && refreshed?.rate.quotaPerUnit == 500000,
            "force refresh normalizes quota using site divisor only")
        let totalAfterRefresh = store.balanceTotalCNY
        try verify(refreshed?.rate.conversionToCNY == nil && totalAfterRefresh.value?.amount == 800,
            "manual FX applies without fabricating raw provider rate")
        let accountAfterRefresh = try repository.account(id: manualAccount.id)
        try verify(accountAfterRefresh?.manualUSDToCNY == 8,
            "force refresh preserves saved manual FX")
        let forcedCalls = await missingClient.count("/api/status")
        try verify(forcedCalls == 2, "manual FX still allows forcing provider parameter refresh")
        let noQuotaClient = DashboardFixtureClient(dashboard: data,
            status: #"{"success":true,"data":{"credit_currency":"USD","usd_exchange_rate":7.3}}"#)
        do {
            _ = try await PipioAdapter(client: noQuotaClient).fetchAccountRate(for: manualAccount, credential: credential)
            throw PipioCheckFailure(message: "manual FX must not substitute missing quota_per_unit")
        } catch ProviderError.missingRate {}
        print("PASSED: Pipio dashboard endpoint, five models, tokens/cache coverage, optional rows, account FX and legacy refresh")
    }
}
