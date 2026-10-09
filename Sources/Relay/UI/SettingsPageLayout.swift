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

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 16, weight: .medium))
                        Text(tab.title)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                    .background(
                        selectedTab == tab ? Color.accentColor.opacity(0.13) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    // 让整个分页单元格（包括图标和文字周围的空白）参与命中测试。
                    // 未选中项使用透明背景，若没有显式 contentShape，SwiftUI 可能只命中实际绘制内容。
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                .accessibilityLabel(tab.title)
            }
        }
        .padding(.horizontal, 14)
    }
}

@MainActor
struct SettingsPageScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16, content: content)
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
        }
    }
}
