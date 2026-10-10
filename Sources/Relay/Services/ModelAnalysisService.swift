import Foundation

public enum ModelAnalysisSort: String, CaseIterable, Identifiable, Sendable {
    case spend = "消费"
    case tokens = "Token"
    case name = "名称"
    public var id: String { rawValue }
}

public struct ModelAnalysisRow: Identifiable, Sendable {
    public let item: ModelUsageItem
    public let spendShare: Decimal?
    public let costPerMillionTokens: MoneyValue?
    public var id: String { item.id }
}

public struct ModelAnalysisResult: Sendable {
    public let rows: [ModelAnalysisRow]
    public let spendTotals: [Currency: Decimal]
    public let hasUnknownSpend: Bool
    public let hasMixedCurrencies: Bool
    public var canShowShare: Bool { !hasUnknownSpend && !hasMixedCurrencies }
}

public enum ModelAnalysisService {
    public static func analyze(_ items: [ModelUsageItem], sort: ModelAnalysisSort = .spend, topFive: Bool = false) -> ModelAnalysisResult {
        var totals: [Currency: Decimal] = [:]
        var hasUnknown = false
        for item in items {
            if let value = validCost(item.cost) { totals[item.currency, default: 0] += value }
            else { hasUnknown = true }
        }
        let mixed = totals.count > 1
        let sorted = items.sorted { left, right in
            switch sort {
            case .name: break
            case .tokens:
                let leftValue = validTokens(left.tokenCount), rightValue = validTokens(right.tokenCount)
                if leftValue != rightValue {
                    if let leftValue, let rightValue { return leftValue > rightValue }
                    return leftValue != nil
                }
            case .spend:
                // Comparing raw USD and CNY amounts would manufacture a ranking.
                // Group native currencies first; never apply an inferred rate.
                if mixed && left.currency != right.currency { return left.currency.rawValue < right.currency.rawValue }
                let leftValue = validCost(left.cost), rightValue = validCost(right.cost)
                if leftValue != rightValue {
                    if let leftValue, let rightValue { return leftValue > rightValue }
                    return leftValue != nil
                }
            }
            if left.modelName != right.modelName { return left.modelName < right.modelName }
            return left.id < right.id
        }
        let rows = (topFive ? Array(sorted.prefix(5)) : sorted).map { item -> ModelAnalysisRow in
            let cost = validCost(item.cost)
            let total = totals[item.currency]
            let share = !hasUnknown && !mixed && (total ?? 0) > 0 ? cost.map { $0 / total! } : nil
            let unitCost: MoneyValue?
            if let cost, let count = validTokens(item.tokenCount), count > 0 {
                unitCost = MoneyValue(amount: cost / Decimal(count) * 1_000_000, currency: item.currency)
            } else { unitCost = nil }
            return ModelAnalysisRow(item: item, spendShare: share, costPerMillionTokens: unitCost)
        }
        return ModelAnalysisResult(rows: rows, spendTotals: totals, hasUnknownSpend: hasUnknown, hasMixedCurrencies: mixed)
    }

    private static func validCost(_ value: Decimal?) -> Decimal? {
        guard let value, !value.isNaN, value >= 0 else { return nil }
        return value
    }

    private static func validTokens(_ value: Int64?) -> Int64? {
        guard let value, value >= 0 else { return nil }
        return value
    }
}
