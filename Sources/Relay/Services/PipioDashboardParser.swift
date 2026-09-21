import Foundation

/// The public Pipio analytics UI's model-token table uses /api/data/self,
/// not request logs or /api/data/flow/self. Rows are time buckets per model.
/// Keep optional metrics unknown when the provider hasn't tracked full coverage.
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

    static func models(from data: Data, range: DateInterval, quotaPerUnit: Decimal, currency: Currency) throws -> [ModelUsageSummary] {
        guard quotaPerUnit > 0 else { throw ProviderError.missingRate }
        let envelope: Envelope
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch { throw ProviderError.incompatibleResponse }
        guard envelope.success != false, let points = envelope.data else { throw ProviderError.incompatibleResponse }
        let start = Int64(range.start.timeIntervalSince1970)
        let end = Int64(range.end.timeIntervalSince1970)
        let groups = Dictionary(grouping: points.filter { $0.createdAt >= start && $0.createdAt <= end }) {
            let name = $0.modelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? "未标明模型" : name
        }
        return try groups.compactMap { name, rows in
            let tokens = try sum(rows.map(\.tokenUsed))
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
            return ModelUsageSummary(
                modelName: name, tokenCount: tokens, requestCount: count,
                cacheHitRate: cacheShare,
                spend: quota.map { MoneyValue(amount: $0 / quotaPerUnit, currency: currency) }
            )
        }.sorted {
            let lhsTokens = $0.tokenCount ?? 0
            let rhsTokens = $1.tokenCount ?? 0
            if lhsTokens != rhsTokens { return lhsTokens > rhsTokens }
            return $0.modelName < $1.modelName
        }
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
