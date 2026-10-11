import Foundation

public struct ConfigurationChange: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let before: String
    public let after: String
}
public struct ConfigurationAccountDiff: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let isNew: Bool
    public let clearsHistory: Bool
    public let needsCredential: Bool
    public let changes: [ConfigurationChange]
}
public enum ConfigurationDiffService {
    public static func accounts(_ preview: ConfigurationImportPreview, current: RelaySyncData) -> [ConfigurationAccountDiff] {
        preview.archive.accounts.map { incoming in
            let old = current.accounts.first { $0.id == incoming.id }
            let changedDestination = old.map { $0.providerKind != incoming.providerKind || $0.siteOrigin != incoming.siteOrigin } ?? false
            let before = old.map(fields) ?? [:]
            let after = fields(incoming)
            let changes = after.keys.sorted().compactMap { key -> ConfigurationChange? in
                guard before[key] != after[key] else { return nil }
                return ConfigurationChange(id: key, title: key, before: before[key] ?? "无", after: after[key] ?? "无")
            }
            return ConfigurationAccountDiff(id: incoming.id, name: incoming.displayName, isNew: old == nil,
                clearsHistory: changedDestination, needsCredential: old == nil || changedDestination, changes: changes)
        }
    }
    public static func settings(_ preview: ConfigurationImportPreview, current: RelaySyncData) -> [ConfigurationChange] {
        let before = settingsFields(current.settings), after = settingsFields(preview.archive.settings)
        return after.keys.sorted().compactMap { key in
            guard before[key] != after[key] else { return nil }
            return ConfigurationChange(id: key, title: key, before: before[key] ?? "无", after: after[key] ?? "无")
        }
    }
    private static func money(_ value: MoneyValue?) -> String {
        value.map { NSDecimalNumber(decimal: $0.amount).stringValue + " " + $0.currency.rawValue } ?? "关闭"
    }
    private static func fields(_ account: AccountConfiguration) -> [String: String] {
        ["名称": account.displayName, "供应商": account.providerKind.displayName, "站点": account.siteOrigin.absoluteString,
         "启用": account.isEnabled ? "是" : "否", "隐藏": account.isHidden ? "是" : "否",
         "分组": account.groupName ?? "未分组", "置顶": account.isPinned ? "是" : "否", "月预算": money(account.monthlyBudget),
         "低余额阈值": account.lowBalanceThreshold.map { NSDecimalNumber(decimal: $0).stringValue } ?? "关闭",
         "美元汇率覆盖": account.manualUSDToCNY.map { NSDecimalNumber(decimal: $0).stringValue } ?? "自动",
         "排序": String(account.sortOrder)]
    }
    private static func settingsFields(_ settings: RelaySettings) -> [String: String] {
        ["刷新间隔（秒）": String(settings.refreshIntervalSeconds), "菜单栏今日消费": settings.showTodayInMenuBar ? "显示" : "隐藏",
         "基础币种": settings.baseCurrency.rawValue, "默认低余额阈值": NSDecimalNumber(decimal: settings.defaultLowBalanceThreshold).stringValue,
         "历史保留": settings.historyRetention.rawValue]
    }
}
