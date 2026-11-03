import Foundation

/// Select by real provider date, never by the chart's abbreviated display label.
public enum DailyModelUsageService {
    public static func trendPoints(accountID: UUID, provider: ProviderKind, records: [DailyUsageRecord],
                                   currency: Currency, now: Date = Date(), calendar: Calendar = .current) -> [DailySpendPoint] {
        let calendar = BudgetService.calendar(for: provider, fallback: calendar)
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -6, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return [] }
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "MM/dd"
        let days = Dictionary(records.filter { $0.accountID == accountID && $0.day >= start && $0.day < end }
            .map { (calendar.startOfDay(for: $0.day), $0) }, uniquingKeysWith: { $0.updatedAt > $1.updatedAt ? $0 : $1 })
        return days.values.sorted { $0.day < $1.day }.compactMap { record in
            guard let spend = record.spend, spend.currency == currency, !spend.amount.isNaN, spend.amount >= 0 else { return nil }
            return DailySpendPoint(id: record.id, dateString: formatter.string(from: record.day), amount: spend.amount, day: record.day)
        }
    }

    /// A partial list never turns missing token counts into zero or wraps on overflow.
    public static func tokenCount(_ models: [ModelUsageSummary]?) -> Int64? {
        guard let models else { return nil }
        var total: Int64 = 0
        for model in models {
            guard let tokens = model.tokenCount, tokens >= 0 else { return nil }
            let sum = total.addingReportingOverflow(tokens)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }

    public static func models(accountID: UUID, provider: ProviderKind, day: Date,
                              records: [DailyUsageRecord], snapshot: ProviderSnapshot?,
                              calendar: Calendar = .current) -> [ModelUsageSummary]? {
        guard provider != .workbuddy2api else { return nil }
        let calendar = BudgetService.calendar(for: provider, fallback: calendar)
        if let record = records.filter({ $0.accountID == accountID && calendar.isDate($0.day, inSameDayAs: day) })
            .max(by: { $0.updatedAt < $1.updatedAt }), let models = record.modelUsages {
            return models
        }
        // Legacy Pipio snapshots were already daily. Legacy DeepSeek snapshots
        // were monthly, so they must never be relabelled as a selected day's data.
        if provider == .pipio, let snapshot, snapshot.accountID == accountID,
           calendar.isDate(snapshot.fetchedAt, inSameDayAs: day) {
            return snapshot.modelUsages
        }
        return nil
    }
}
