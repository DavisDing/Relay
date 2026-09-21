import Foundation

/// Shared content for the AppKit status item and SwiftUI preview. No balance or currency label.
struct MenuBarStatusPresentation {
    let title: String
    let symbolName: String
    let statusDescription: String

    init(todaySpendAmount: Decimal?, isRefreshing: Bool = false, hasWarning: Bool = false) {
        title = todaySpendAmount.map(RelayNumberFormatter.decimal) ?? ""
        symbolName = isRefreshing ? "arrow.triangle.2.circlepath" : (hasWarning ? "exclamationmark.triangle.fill" : "bolt.fill")
        statusDescription = isRefreshing ? "正在刷新" : (hasWarning ? "账户需要关注" : "Relay")
    }

    var toolTip: String {
        (["Relay", statusDescription == "Relay" ? nil : statusDescription,
          title.isEmpty ? nil : "今日消费 " + title, "左键打开，右键显示菜单"] as [String?])
            .compactMap { $0 }.joined(separator: " · ")
    }
}
