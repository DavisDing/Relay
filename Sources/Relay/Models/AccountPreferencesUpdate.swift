import Foundation

/// Preserve preferences when an older caller edits unrelated account fields.
/// `.set` carries all form values so one account upsert commits the whole edit.
public enum AccountPreferencesUpdate: Sendable {
    case unchanged
    case set(monthlyBudget: MoneyValue?, groupName: String?, isPinned: Bool)
}

public enum AccountPreferencesValidation {
    public static func validate(monthlyBudget: MoneyValue?, groupName: String?, provider: ProviderKind) throws {
        if let monthlyBudget {
            guard provider != .workbuddy2api else { throw AccountPreferencesError.unsupportedBudget }
            guard !monthlyBudget.amount.isNaN, monthlyBudget.amount > 0 else {
                throw AccountPreferencesError.invalidBudget
            }
        }
        let group = groupName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (group?.count ?? 0) <= 40 else { throw AccountPreferencesError.groupTooLong }
    }
}

public enum AccountPreferencesError: Error, LocalizedError {
    case invalidBudget
    case unsupportedBudget
    case groupTooLong

    public var errorDescription: String? {
        switch self {
        case .invalidBudget: return "月预算必须是大于零的有效金额；留空可关闭预算。"
        case .unsupportedBudget: return "此网关没有可靠的月消费，暂不支持月预算。"
        case .groupTooLong: return "分组名称最多 40 个字符。"
        }
    }
}
