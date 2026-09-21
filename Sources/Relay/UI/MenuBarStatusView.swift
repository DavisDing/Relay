import SwiftUI

/// SwiftUI counterpart of the AppKit status item: monochrome symbol and today's spend only.
public struct MenuBarStatusView: View {
    public let todaySpendAmount: Decimal?
    public let isRefreshing: Bool
    public let hasWarning: Bool
    public let fixedWidth: Bool

    public init(todaySpendAmount: Decimal? = nil,
                isRefreshing: Bool = false,
                hasWarning: Bool = false,
                fixedWidth: Bool = true) {
        self.todaySpendAmount = todaySpendAmount
        self.isRefreshing = isRefreshing
        self.hasWarning = hasWarning
        self.fixedWidth = fixedWidth
    }

    public var body: some View {
        let presentation = MenuBarStatusPresentation(
            todaySpendAmount: todaySpendAmount, isRefreshing: isRefreshing, hasWarning: hasWarning
        )
        HStack(spacing: 4) {
            Image(systemName: presentation.symbolName)
                .symbolRenderingMode(.monochrome)
            if !presentation.title.isEmpty {
                Text(presentation.title)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 4)
        .frame(maxWidth: fixedWidth && !presentation.title.isEmpty ? 70 : nil)
        .help(presentation.toolTip)
        .clipped()
    }
}
