import Foundation

/// The public Pipio analytics UI's model-token table uses /api/data/self,
/// not request logs or /api/data/flow/self. Rows are time buckets per model.
/// Prefer the provider total and cache contract; derive missing metrics only from valid raw counts.
enum PipioDashboardParser {
    private struct Envelope: Decodable {
        let success: Bool?
        let data: [Point]?
    }

    private struct Point: Decodable {
        let createdAt: Int64
        let modelName: String?
        let quota: Decimal?
        let count: Int64?
        let tokenUsed: Int64?
        let inputTokens: Int64?
        let outputTokens: Int64?
        let cacheReadTokens: Int64?
        let cacheWriteTokens: Int64?
        let tokenBreakdownCount: Int64?
        let tokenBreakdownRequestCount: Int64?
        let tokenBreakdownTrackedTokenUsed: Int64?
        let cacheMetricsRequestCount: Int64?
        let cacheEligibleInputTokens: Int64?

        // Pipio reports ordinary input, cache reads and cache writes as separate components.
        // Do not compare cache reads to ordinary input or substitute token_used - output:
        // provider totals may cover more requests than the available token breakdown.
        func resolvedInputTokenCount() throws -> Int64? {
            try PipioDashboardParser.sum([inputTokens, cacheReadTokens, cacheWriteTokens])
        }

        func resolvedTokenCount() throws -> Int64? {
            if let tokenUsed { return tokenUsed >= 0 ? tokenUsed : nil }
            return try PipioDashboardParser.sum([resolvedInputTokenCount(), outputTokens])
        }

        var hasCacheContract: Bool {
            guard let tokens = tokenUsed, tokens >= 0,
                  let tracked = tokenBreakdownTrackedTokenUsed, tracked == tokens,
                  let reported = tokenBreakdownCount, reported >= 0,
                  let expected = tokenBreakdownRequestCount, expected >= 0,
                  let metrics = cacheMetricsRequestCount, metrics >= 0,
                  let eligible = cacheEligibleInputTokens, eligible >= 0,
                  let read = cacheReadTokens, read >= 0,
                  let input = inputTokens, input >= 0,
                  let output = outputTokens, output >= 0,
                  let write = cacheWriteTokens, write >= 0 else { return false }
            return reported == expected && metrics == reported
        }
    }

    struct Usage {
        let spend: MoneyValue?
        let models: [ModelUsageSummary]?
    }

    /// The website's overview and model analysis both aggregate the same dashboard buckets.
    /// Compute the total from raw quotas, never from rounded UI strings or log/stat.
    static func usage(from data: Data, range: DateInterval, quotaPerUnit: Decimal, currency: Currency) throws -> Usage {
        guard quotaPerUnit > 0 else { throw ProviderError.missingRate }
        let points = try points(from: data, range: range)
        let quota: Decimal? = points.allSatisfy { $0.quota != nil }
            ? points.reduce(.zero) { $0 + ($1.quota ?? .zero) } : nil
        let spend = quota.flatMap { total -> MoneyValue? in
            let amount = total / quotaPerUnit
            return amount.isNaN ? nil : MoneyValue(amount: amount, currency: currency)
        }
        // Optional token breakdown failures must not discard a valid monetary total.
        return Usage(spend: spend, models: try? models(points: points, quotaPerUnit: quotaPerUnit, currency: currency))
    }

    static func models(from data: Data, range: DateInterval, quotaPerUnit: Decimal, currency: Currency) throws -> [ModelUsageSummary] {
        guard quotaPerUnit > 0 else { throw ProviderError.missingRate }
        return try models(points: points(from: data, range: range), quotaPerUnit: quotaPerUnit, currency: currency)
    }

    private static func points(from data: Data, range: DateInterval) throws -> [Point] {
        let envelope: Envelope
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch { throw ProviderError.incompatibleResponse }
        guard envelope.success != false, let points = envelope.data else { throw ProviderError.incompatibleResponse }
        let start = Int64(range.start.timeIntervalSince1970)
        let end = Int64(range.end.timeIntervalSince1970)
        return points.filter { $0.createdAt >= start && $0.createdAt <= end }
    }

    private static func models(points: [Point], quotaPerUnit: Decimal, currency: Currency) throws -> [ModelUsageSummary] {
        let groups = Dictionary(grouping: points) {
            let name = $0.modelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? "未标明模型" : name
        }
        return try groups.compactMap { name, rows in
            let tokens = try sum(rows.map { try $0.resolvedTokenCount() })
            let count = try sum(rows.map(\.count))
            let quota: Decimal? = rows.allSatisfy { $0.quota != nil }
                ? rows.reduce(.zero) { $0 + ($1.quota ?? .zero) } : nil
            // A free model with tokens/requests is still a real model row.
            if tokens == 0 && count == 0 && quota == .zero { return nil }
            var cacheShare: Decimal?
            if rows.allSatisfy(\.hasCacheContract),
               let requests = try sum(rows.map(\.tokenBreakdownRequestCount)), requests > 0,
               let eligible = try sum(rows.map(\.cacheEligibleInputTokens)), eligible > 0,
               let read = try sum(rows.map(\.cacheReadTokens)), read <= eligible {
                cacheShare = Decimal(read) / Decimal(eligible)
            }
            // User-selected fallback for N/A: weighted model-level cache reads / all inputs.
            // Do not average bucket percentages, treat missing counts as zero, or divide by zero.
            if cacheShare == nil,
               let input = try sum(rows.map { try $0.resolvedInputTokenCount() }), input > 0,
               let read = try sum(rows.map(\.cacheReadTokens)) {
                cacheShare = Decimal(read) / Decimal(input)
            }
            return ModelUsageSummary(
                modelName: name, tokenCount: tokens, requestCount: count,
                cacheHitRate: cacheShare,
                spend: quota.map { MoneyValue(amount: $0 / quotaPerUnit, currency: currency) }
            )
        }.sorted(by: ModelUsageSummary.spendDescending)
    }

    private static func sum(_ values: [Int64?]) throws -> Int64? {
        var total: Int64 = 0
        for value in values {
            guard let value, value >= 0 else { return nil }
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { throw ProviderError.incompatibleResponse }
            total = result.partialValue
        }
        return total
    }
}
