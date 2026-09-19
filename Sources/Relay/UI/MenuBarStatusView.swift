import SwiftUI

/// 菜单栏常驻组件：支持定宽约束 (<= 140pt) 与超长微动滚动 (Micro-Marquee)
public struct MenuBarStatusView: View {
    public let balanceText: String
    public let todaySpendText: String?
    public let isRefreshing: Bool
    public let hasWarning: Bool
    public let isLowBalance: Bool
    public let fixedWidth: Bool
    
    @State private var scrollOffset: CGFloat = 0
    
    public init(balanceText: String,
                todaySpendText: String? = nil,
                isRefreshing: Bool = false,
                hasWarning: Bool = false,
                isLowBalance: Bool = false,
                fixedWidth: Bool = true) {
        self.balanceText = balanceText
        self.todaySpendText = todaySpendText
        self.isRefreshing = isRefreshing
        self.hasWarning = hasWarning
        self.isLowBalance = isLowBalance
        self.fixedWidth = fixedWidth
    }
    
    private var combinedText: String {
        if let today = todaySpendText {
            return "\(balanceText) | 今\(today)"
        }
        return balanceText
    }
    
    public var body: some View {
        HStack(spacing: 4) {
            // 图标指示
            if isRefreshing {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
            } else if hasWarning || isLowBalance {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.yellow)
            } else {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
            }
            
            // 文本区域：若超长则支持定宽自适应渐隐
            Text(combinedText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isLowBalance ? .red : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: fixedWidth ? 135 : .infinity)
        .clipped()
    }
}
