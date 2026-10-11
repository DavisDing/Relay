import Foundation

/// Select by real provider date, never by the chart's abbreviated display label.
public enum DailyModelUsageService {
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
