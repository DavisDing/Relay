import Foundation

public protocol DeepSeekUsageProviding: Sendable {
    func fetchUsage(
        query: DeepSeekUsageQuery,
        credential: ProviderCredential
    ) async throws -> DeepSeekUsageReport

    func probe() -> DeepSeekUsageCoverage
}

/// DeepSeek platform usage client.
///
/// The API key is used by `DeepSeekAdapter` for the official balance endpoint.
/// Historical usage is a separate platform flow authenticated by the optional,
/// user-entered `deepSeekUserToken`. Relay never reads browser cookies.
public struct DeepSeekUsageService: DeepSeekUsageProviding, Sendable {
    private let client: any HTTPClient

    private static let platformOrigin = URL(string: "https://platform.deepseek.com")!
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
    private static let referer = "https://platform.deepseek.com/usage"

    /// DeepSeek platform usage is presented in Beijing time. Keep the
    /// provider's month/day boundaries independent from the Mac's local
    /// timezone so history has the same meaning on every machine.
    public static var historyCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        return calendar
    }

    public init(client: any HTTPClient = URLSessionHTTPClient()) {
        self.client = client
    }

    public func fetchUsage(
        query: DeepSeekUsageQuery,
        credential: ProviderCredential
    ) async throws -> DeepSeekUsageReport {
        try validate(query: query, credential: credential)
        guard let token = normalizedToken(from: credential) else {
            return .unsupported(accountID: query.accountID, reason: .userTokenNotConfigured)
        }

        // The platform contract is a Beijing-time history, regardless of the
        // presentation calendar supplied by a caller.
        let calendar = Self.historyCalendar
        let months = try monthKeysCovering(query.startAt, query.endAt, calendar: calendar)
        var accumulator = UsageAccumulator(calendar: calendar)
        for month in months {
            let usage = try await fetchMonthUsage(month: month, token: token)
            accumulator.merge(usage, start: query.startAt, end: query.endAt)
        }
        return accumulator.report(accountID: query.accountID, fetchedAt: Date())
    }

    public func probe() -> DeepSeekUsageCoverage { .complete }

    public func fetchDailyUsage(
        accountID: UUID,
        startAt: Date,
        endAt: Date,
        calendar _: Calendar,
        credential: ProviderCredential
    ) async throws -> [DailyUsageRecord] {
        guard normalizedToken(from: credential) != nil else { return [] }
        let historyCalendar = Self.historyCalendar
        let report = try await fetchUsage(
            query: DeepSeekUsageQuery(
                accountID: accountID,
                siteOrigin: Self.platformOrigin,
                startAt: startAt,
                endAt: endAt,
                calendar: historyCalendar
            ),
            credential: credential
        )
        return (report.daily ?? []).map {
            DailyUsageRecord(
                accountID: accountID,
                day: historyCalendar.startOfDay(for: $0.day),
                spend: $0.spend,
                updatedAt: report.fetchedAt
            )
        }
    }

    public func fetchCurrentMonth(
        accountID: UUID,
        now: Date,
        calendar _: Calendar,
        credential: ProviderCredential
    ) async throws -> DeepSeekUsageSummary? {
        guard let token = normalizedToken(from: credential) else { return nil }
        let historyCalendar = Self.historyCalendar
        let components = historyCalendar.dateComponents([.year, .month], from: now)
        guard let year = components.year, let month = components.month else {
            throw DeepSeekUsageServiceError.invalidDateRange
        }
        let usage = try await fetchMonthUsage(month: MonthKey(year: year, month: month), token: token)
        var accumulator = UsageAccumulator(calendar: historyCalendar)
        accumulator.merge(usage, start: nil, end: nil)
        return accumulator.summary(now: now)
    }

    private func validate(query: DeepSeekUsageQuery, credential: ProviderCredential) throws {
        guard !credential.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.invalidCredential
        }
        guard query.startAt <= query.endAt else {
            throw DeepSeekUsageServiceError.invalidDateRange
        }
        _ = try ProviderURLNormalizer.secureOrigin(from: query.siteOrigin)
        if let token = credential.deepSeekUserToken,
           token.trimmingCharacters(in: .whitespacesAndNewlines).count > 4096 {
            throw DeepSeekUsageServiceError.invalidUserToken
        }
    }

    private func normalizedToken(from credential: ProviderCredential) -> String? {
        let token = credential.deepSeekUserToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return token.isEmpty ? nil : token
    }

    private func monthKeysCovering(_ start: Date, _ end: Date, calendar: Calendar) throws -> [MonthKey] {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: start)),
              let last = calendar.date(from: calendar.dateComponents([.year, .month], from: end)) else {
            throw DeepSeekUsageServiceError.invalidDateRange
        }
        var result: [MonthKey] = []
        var cursor = first
        while cursor <= last && result.count < 24 {
            let c = calendar.dateComponents([.year, .month], from: cursor)
            if let year = c.year, let month = c.month { result.append(MonthKey(year: year, month: month)) }
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        guard !result.isEmpty, cursor > last else { throw DeepSeekUsageServiceError.rangeTooLarge }
        return result
    }

    private func fetchMonthUsage(month: MonthKey, token: String) async throws -> MonthUsage {
        async let amount = fetchUsagePayload(path: "/api/v0/usage/amount", month: month, token: token)
        async let cost = fetchUsagePayload(path: "/api/v0/usage/cost", month: month, token: token)
        return try await MonthUsage(amount: amount, cost: cost)
    }

    private func fetchUsagePayload(path: String, month: MonthKey, token: String) async throws -> UsageEnvelope {
        let endpoint = Self.platformOrigin.appendingPathComponent(String(path.dropFirst()))
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw DeepSeekUsageServiceError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "month", value: String(month.month)),
            URLQueryItem(name: "year", value: String(month.year))
        ]
        guard let url = components.url else { throw DeepSeekUsageServiceError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.referer, forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await client.data(for: request)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw DeepSeekUsageServiceError.userTokenUnauthorized
        }
        try HTTPResponseValidator.validate(response)
        do {
            return try JSONDecoder().decode(UsageEnvelope.self, from: data)
        } catch {
            throw DeepSeekUsageServiceError.invalidResponse
        }
    }
}

public struct DeepSeekUsageSummary: Sendable, Equatable {
    public let todaySpend: MoneyValue?
    public let monthSpend: MoneyValue?
    public let requestCount: Int64?
    public let modelUsages: [ModelUsageSummary]?
    public let daily: [DeepSeekDailyUsage]

    public init(
        todaySpend: MoneyValue?,
        monthSpend: MoneyValue?,
        requestCount: Int64?,
        modelUsages: [ModelUsageSummary]?,
        daily: [DeepSeekDailyUsage]
    ) {
        self.todaySpend = todaySpend
        self.monthSpend = monthSpend
        self.requestCount = requestCount
        self.modelUsages = modelUsages
        self.daily = daily
    }
}

private struct MonthKey: Equatable {
    let year: Int
    let month: Int
}

private struct UsageEnvelope: Decodable {
    let data: UsageData

    private enum CodingKeys: String, CodingKey { case data }

    init(from decoder: Decoder) throws {
        data = try decoder.container(keyedBy: CodingKeys.self).decode(UsageData.self, forKey: .data)
    }
}

/// DeepSeek currently returns `biz_data` as an object for amount and as an
/// array of currency objects for cost. Decode both forms because this is an
/// internal dashboard endpoint and the wrapper has changed shape over time.
private struct UsageData: Decodable {
    let bizData: UsageBizData

    private enum CodingKeys: String, CodingKey { case bizData = "biz_data" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let object = try? container.decode(UsageBizData.self, forKey: .bizData) {
            bizData = object
        } else {
            let groups = try container.decode([UsageCostGroup].self, forKey: .bizData)
            let first = groups.first
            bizData = UsageBizData(
                total: first?.total ?? [],
                days: first?.days ?? [],
                currency: first?.currency
            )
        }
    }
}

private struct UsageBizData: Decodable {
    let total: [UsageModelBucket]
    let days: [UsageDayBucket]
    let currency: Currency?

    init(total: [UsageModelBucket], days: [UsageDayBucket], currency: Currency? = nil) {
        self.total = total
        self.days = days
        self.currency = currency
    }

    private enum CodingKeys: String, CodingKey { case total, days, currency }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = (try? c.decode([UsageModelBucket].self, forKey: .total))
            ?? (try? [c.decode(UsageModelBucket.self, forKey: .total)])
            ?? []
        days = (try? c.decode([UsageDayBucket].self, forKey: .days))
            ?? (try? [c.decode(UsageDayBucket.self, forKey: .days)])
            ?? []
        currency = try? c.decodeIfPresent(Currency.self, forKey: .currency)
    }
}

private struct UsageCostGroup: Decodable {
    let currency: Currency?
    let total: [UsageModelBucket]
    let days: [UsageDayBucket]

    private enum CodingKeys: String, CodingKey { case currency, total, days }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currency = try? c.decodeIfPresent(Currency.self, forKey: .currency)
        total = (try? c.decode([UsageModelBucket].self, forKey: .total))
            ?? (try? [c.decode(UsageModelBucket.self, forKey: .total)])
            ?? []
        days = (try? c.decode([UsageDayBucket].self, forKey: .days))
            ?? (try? [c.decode(UsageDayBucket.self, forKey: .days)])
            ?? []
    }
}

private struct UsageModelBucket: Decodable {
    let model: String?
    let usage: [UsageItem]

    private enum CodingKeys: String, CodingKey { case model, modelName = "model_name", usage }

    init(model: String?, usage: [UsageItem]) {
        self.model = model
        self.usage = usage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = (try? c.decode(String.self, forKey: .model))
            ?? (try? c.decode(String.self, forKey: .modelName))
        usage = (try? c.decode([UsageItem].self, forKey: .usage)) ?? []
    }
}

private struct UsageDayBucket: Decodable {
    let date: String?
    let data: [UsageModelBucket]

    private enum CodingKeys: String, CodingKey { case date, day, data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? c.decode(String.self, forKey: .date))
            ?? (try? c.decode(String.self, forKey: .day))
        data = (try? c.decode([UsageModelBucket].self, forKey: .data))
            ?? (try? [c.decode(UsageModelBucket.self, forKey: .data)])
            ?? []
    }
}

private struct UsageItem: Decodable {
    let type: String?
    let amount: Decimal

    private enum CodingKeys: String, CodingKey { case type, amount, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decode(String.self, forKey: .type)
        let key: CodingKeys = (c.contains(.amount) ? .amount : .value)
        if let value = try? c.decode(String.self, forKey: key),
           let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) {
            amount = decimal
        } else if let value = try? c.decode(Double.self, forKey: key) {
            amount = Decimal(value)
        } else if let value = try? c.decode(Int64.self, forKey: key) {
            amount = Decimal(value)
        } else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "amount is not numeric")
        }
    }
}

private struct MonthUsage {
    let amountTotal: [UsageModelBucket]
    let amountDays: [UsageDayBucket]
    let costTotal: [UsageModelBucket]
    let costDays: [UsageDayBucket]
    let currency: Currency

    init(amount: UsageEnvelope, cost: UsageEnvelope) {
        let amountBiz = amount.data.bizData
        let costBiz = cost.data.bizData
        // The dashboard normally includes `total`, but keep the client usable
        // when an internal response only contains daily rows.
        amountTotal = amountBiz.total.isEmpty ? Self.flatten(amountBiz.days) : amountBiz.total
        amountDays = amountBiz.days
        costTotal = costBiz.total.isEmpty ? Self.flatten(costBiz.days) : costBiz.total
        costDays = costBiz.days
        currency = costBiz.currency ?? .cny
    }

    private static func flatten(_ days: [UsageDayBucket]) -> [UsageModelBucket] {
        var byModel: [String: [UsageItem]] = [:]
        for day in days {
            for bucket in day.data {
                byModel[bucket.model ?? "(unknown)", default: []].append(contentsOf: bucket.usage)
            }
        }
        return byModel.map { model, usage in
            UsageModelBucket(model: model, usage: usage)
        }
    }
}

private struct UsageAccumulator {
    let calendar: Calendar
    var dailyTokens: [String: Int64] = [:]
    var dailyRequests: [String: Int64] = [:]
    var dailyCosts: [String: Decimal] = [:]
    var totalTokens: Int64 = 0
    var totalRequests: Int64 = 0
    var totalCost: Decimal = 0
    var modelTokens: [String: Int64] = [:]
    var modelRequests: [String: Int64] = [:]
    var modelCosts: [String: Decimal] = [:]
    var currency: Currency = .cny
    var hasAmountData = false
    var hasCostData = false

    mutating func merge(_ usage: MonthUsage, start: Date?, end: Date?) {
        currency = usage.currency
        hasAmountData = true
        hasCostData = true
        let amountBuckets = start == nil ? usage.amountTotal : usage.amountDays
            .filter { day in day.date.flatMap(parseDate).map { inRange($0, start: start, end: end) } ?? false }
            .flatMap(\.data)
        let costBuckets = start == nil ? usage.costTotal : usage.costDays
            .filter { day in day.date.flatMap(parseDate).map { inRange($0, start: start, end: end) } ?? false }
            .flatMap(\.data)
        for bucket in amountBuckets {
            let model = bucket.model ?? "(unknown)"
            for item in bucket.usage {
                let value = integerValue(item.amount)
                if item.type == "REQUEST" {
                    totalRequests += value
                    modelRequests[model, default: 0] += value
                } else {
                    totalTokens += value
                    modelTokens[model, default: 0] += value
                }
            }
        }
        for bucket in costBuckets {
            let model = bucket.model ?? "(unknown)"
            for item in bucket.usage where item.type != "REQUEST" {
                totalCost += item.amount
                modelCosts[model, default: 0] += item.amount
            }
        }
        for day in usage.amountDays {
            guard let date = parseDate(day.date), inRange(date, start: start, end: end) else { continue }
            let key = dayKey(date)
            for model in day.data {
                for item in model.usage {
                    let value = integerValue(item.amount)
                    if item.type == "REQUEST" { dailyRequests[key, default: 0] += value }
                    else { dailyTokens[key, default: 0] += value }
                }
            }
        }
        for day in usage.costDays {
            guard let date = parseDate(day.date), inRange(date, start: start, end: end) else { continue }
            let key = dayKey(date)
            for model in day.data {
                for item in model.usage where item.type != "REQUEST" {
                    dailyCosts[key, default: 0] += item.amount
                }
            }
        }
    }

    func report(accountID: UUID, fetchedAt: Date) -> DeepSeekUsageReport {
        DeepSeekUsageReport(
            accountID: accountID,
            coverage: .complete,
            daily: dailyRows,
            models: modelRows.map {
                DeepSeekModelUsage(
                    modelName: $0.modelName,
                    spend: $0.spend,
                    tokenCount: $0.tokenCount,
                    requestCount: $0.requestCount
                )
            },
            fetchedAt: fetchedAt
        )
    }

    func summary(now: Date) -> DeepSeekUsageSummary {
        let todayKey = dayKey(calendar.startOfDay(for: now))
        let todayCost = dailyCosts[todayKey]
        return DeepSeekUsageSummary(
            todaySpend: todayCost.map { MoneyValue(amount: $0, currency: currency) },
            monthSpend: hasCostData ? MoneyValue(amount: totalCost, currency: currency) : nil,
            requestCount: hasAmountData ? totalRequests : nil,
            modelUsages: modelRows,
            daily: dailyRows
        )
    }

    private var dailyRows: [DeepSeekDailyUsage] {
        let keys = Set(dailyTokens.keys).union(dailyRequests.keys).union(dailyCosts.keys)
        return keys.compactMap { key in
            guard let date = dateFromKey(key) else { return nil }
            return DeepSeekDailyUsage(
                day: date,
                spend: dailyCosts[key].map { MoneyValue(amount: $0, currency: currency) },
                tokenCount: dailyTokens[key],
                requestCount: dailyRequests[key]
            )
        }.sorted { $0.day < $1.day }
    }

    private var modelRows: [ModelUsageSummary] {
        let names = Set(modelTokens.keys).union(modelRequests.keys).union(modelCosts.keys)
        return names.map { name in
            ModelUsageSummary(
                modelName: name,
                tokenCount: modelTokens[name],
                requestCount: modelRequests[name],
                spend: modelCosts[name].map { MoneyValue(amount: $0, currency: currency) }
            )
        }.sorted(by: ModelUsageSummary.spendDescending)
    }

    private func integerValue(_ value: Decimal) -> Int64 {
        max(0, NSDecimalNumber(decimal: value).int64Value)
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let normalized: String
        if value.count == 8 && !value.contains("-") {
            normalized = String(value.prefix(4)) + "-" + String(value.dropFirst(4).prefix(2)) + "-" + String(value.suffix(2))
        } else {
            normalized = String(value.prefix(10))
        }
        let parts = normalized.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func dateFromKey(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func dayKey(_ value: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: value)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func inRange(_ date: Date, start: Date?, end: Date?) -> Bool {
        guard let start, let end else { return true }
        let day = calendar.startOfDay(for: date)
        return day >= calendar.startOfDay(for: start) && day <= calendar.startOfDay(for: end)
    }
}

public enum DeepSeekUsageServiceError: Error, Sendable, Equatable, LocalizedError {
    case invalidDateRange
    case invalidUserToken
    case rangeTooLarge
    case invalidResponse
    case userTokenUnauthorized

    public var errorDescription: String? {
        switch self {
        case .invalidDateRange:
            return "用量查询的开始时间不能晚于结束时间。"
        case .invalidUserToken:
            return "DeepSeek userToken 无效或过长。"
        case .rangeTooLarge:
            return "DeepSeek 用量查询范围不能超过 24 个月。"
        case .invalidResponse:
            return "DeepSeek 平台用量接口返回异常。"
        case .userTokenUnauthorized:
            return "DeepSeek userToken 无效或已过期。"
        }
    }
}
