import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case data
    case shortcuts
    case sync
    case accountManagement
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "常规"
        case .data: return "数据"
        case .shortcuts: return "快捷键"
        case .sync: return "同步"
        case .accountManagement: return "账管"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .data: return "chart.bar.xaxis"
        case .shortcuts: return "keyboard"
        case .sync: return "icloud"
        case .accountManagement: return "person.2"
        case .about: return "info.circle"
        }
    }
}

@MainActor
struct SettingsTabBar: View {
    @Binding var selectedTab: SettingsTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 18, weight: .regular))
                            .symbolVariant(selectedTab == tab ? .fill : .none)
                        Text(tab.title)
                            .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(selectedTab == tab ? Color.primary : Color.secondary)
                    .background(
                        selectedTab == tab ? Color.primary.opacity(0.06) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay(alignment: .bottom) {
                        if selectedTab == tab {
                            Capsule().fill(RelayVisualStyle.accentColor).frame(width: 16, height: 2)
                        }
                    }
                    // 让整个分页单元格（包括图标和文字周围的空白）参与命中测试。
                    // 未选中项使用透明背景，若没有显式 contentShape，SwiftUI 可能只命中实际绘制内容。
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                .accessibilityLabel(tab.title)
            }
        }
        .padding(4)
        .relayInsetSurface(cornerRadius: 16)
        .padding(.horizontal, 16)
    }
}

@MainActor
struct SettingsPageScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24, content: content)
                .padding(16)
        }
    }
}
