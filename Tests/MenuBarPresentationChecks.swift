import Foundation

enum MenuBarPresentationChecks {
    static func run() throws {
        func verify(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "MenuBarPresentationChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        try verify(ProviderKind.workbuddy2api.rawValue == "workbuddy2api", "Persisted WordBuddy2Api provider identifier must remain compatible")
        try verify(ProviderKind.workbuddy2api.displayName == "WordBuddy2Api", "WordBuddy2Api display name uses the requested capitalization")
        try verify(RelayNumberFormatter.decimal(Decimal(string: "12.345")!) == "12.35", "Point values round half up to two decimals")
        try verify(RelayNumberFormatter.decimal(Decimal(string: "12")!) == "12.00", "Point values retain two decimal places")

        let normal = MenuBarStatusPresentation(todaySpendAmount: Decimal(string: "1234.567"))
        try verify(normal.title == "1,234.57", "Only today's numeric spend, rounded to two decimals")
        try verify(normal.symbolName == "bolt.fill", "Use a system symbol, not a colored emoji")
        try verify(!normal.title.contains("¥") && !normal.title.contains("$") && !normal.title.contains("今日") && !normal.title.contains("\n"), "No currency, labels or balance line")
        let zero = MenuBarStatusPresentation(todaySpendAmount: .zero)
        try verify(zero.title == "0.00", "Known zero spend stays visible")
        let missing = MenuBarStatusPresentation(todaySpendAmount: nil)
        try verify(missing.title.isEmpty && missing.symbolName == "bolt.fill", "Unknown/disabled spend keeps only an entry icon")
        let refreshing = MenuBarStatusPresentation(todaySpendAmount: 12, isRefreshing: true, hasWarning: true)
        try verify(refreshing.symbolName == "arrow.triangle.2.circlepath" && refreshing.title == "12.00", "Refreshing retains numeric spend")
        let warning = MenuBarStatusPresentation(todaySpendAmount: nil, hasWarning: true)
        try verify(warning.symbolName == "exclamationmark.triangle.fill" && warning.title.isEmpty, "Warning does not fabricate spend")
        try verify(normal.toolTip.contains("今日消费 1,234.57"), "Full amount is readable in tooltip")
        print("PASSED: menu bar numeric-only spend, system symbols, zero/missing/refresh/warning states")
    }
}
