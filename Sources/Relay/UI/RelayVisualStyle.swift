import SwiftUI

/// Apple Design expressed through native macOS surfaces and semantic colors.
/// Material belongs to the outer chrome; content stays on quiet, readable surfaces.
public enum RelayVisualStyle {
    public static let panelWidth: CGFloat = 320
    public static let panelHeight: CGFloat = 480
    public static let detailPanelWidth: CGFloat = 560
    public static let detailPanelHeight: CGFloat = 500
    public static let formPanelWidth: CGFloat = 360
    public static let formPanelHeight: CGFloat = 480
    public static let settingsPanelWidth: CGFloat = 380
    public static let settingsPanelHeight: CGFloat = 500
    public static let auxiliaryPanelCornerRadius: CGFloat = 16
    public static let buttonHeight: CGFloat = 26
    public static let iconButtonDiameter: CGFloat = 24
    public static let inputHeight: CGFloat = 28
    public static let navigationHeight: CGFloat = 30
    public static let buttonFontSize: CGFloat = 12
    public static let bodyFontSize: CGFloat = 12
    public static let radiusSmall: CGFloat = 8
    public static let radiusMedium: CGFloat = 10
    public static let radiusCard: CGFloat = 13
    public static let radiusPanel: CGFloat = 16
    public static let radiusLarge: CGFloat = 24
    public static let radiusFAB: CGFloat = 16
    public static let cardCornerRadius: CGFloat = radiusCard
    public static let panelCornerRadius: CGFloat = radiusPanel
    public static let spacingTight: CGFloat = 8
    public static let spacingStandard: CGFloat = 12
    public static let spacingSection: CGFloat = 16
    public static let spacingLoose: CGFloat = 20
    public static let accentColor: Color = .accentColor
    public static let destructiveColor: Color = .red
    public static let darkCardColor = Color(nsColor: .controlBackgroundColor)
    public static let disclosureAnimation = Animation.spring(response: 0.32, dampingFraction: 1)

    public static func preferredColorScheme(for mode: AppearanceMode) -> ColorScheme? {
        switch mode {
        case .followSystem: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// One title bar for every auxiliary page; keep navigation, type and insets identical.
struct RelayPageHeader: View {
    let title: String
    let onBack: () -> Void
    var accessorySystemImage: String? = nil
    var accessoryLabel: String = ""
    var onAccessory: () -> Void = {}
    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .buttonStyle(RelayCircularIconButtonStyle())
                .help("返回首页").accessibilityLabel("返回首页")
            Text(title).font(.system(size: 16, weight: .semibold))
            Spacer(minLength: 0)
            if let accessorySystemImage {
                Button(action: onAccessory) { Image(systemName: accessorySystemImage) }
                    .buttonStyle(RelayCircularIconButtonStyle())
                    .help(accessoryLabel).accessibilityLabel(accessoryLabel)
            }
        }
        .frame(height: RelayVisualStyle.navigationHeight)
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
    }
}

/// Actions sit on the page itself, separated by a quiet inset rule, never a second panel.
struct RelayPageFooter<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 10, content: content)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .overlay(alignment: .top) { Divider().opacity(0.35).padding(.horizontal, 14) }
    }
}

private struct RelaySurface: ViewModifier {
    enum Kind { case panel, content, inset, toolbar }
    let kind: Kind
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if kind == .panel || kind == .toolbar {
                    if reduceTransparency || contrast == .increased {
                        shape.fill(Color(nsColor: .windowBackgroundColor))
                    } else {
                        shape.fill(.regularMaterial)
                            .overlay {
                                if kind == .panel {
                                    shape.fill(scheme == .dark
                                        ? Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.84)
                                        : Color(red: 0.96, green: 0.97, blue: 0.99).opacity(0.82))
                                } else {
                                    shape.fill((scheme == .dark ? Color.black : Color.white).opacity(0.12))
                                }
                            }
                    }
                } else {
                    shape.fill(kind == .content
                        ? Color(nsColor: .controlBackgroundColor)
                        : Color.primary.opacity(scheme == .dark ? 0.07 : 0.035))
                }
            }
            .overlay {
                shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.45 : (kind == .inset ? 0.04 : 0.08)),
                                   lineWidth: contrast == .increased ? 1 : 0.5)
                    .allowsHitTesting(false)
            }
            .tint(.accentColor)
    }
}

/// Press feedback is immediate; the release settles without overshoot.
/// Only the release is animated, so a new press never waits for an animation.
public struct RelayPrimaryCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public let height: CGFloat
    public let isLoading: Bool
    public init(height: CGFloat = RelayVisualStyle.buttonHeight, isLoading: Bool = false) {
        self.height = height; self.isLoading = isLoading
    }
    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            if isLoading { ProgressView().controlSize(.small); Text("处理中…") }
            else { configuration.label }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 15)
        .frame(minHeight: height)
        .background(configuration.role == .destructive ? Color.red : .accentColor, in: Capsule())
        .contentShape(Capsule())
        .brightness(configuration.isPressed ? -0.08 : 0)
        .opacity(isEnabled || isLoading ? 1 : 0.4)
        .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
        .animation(configuration.isPressed || reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1), value: configuration.isPressed)
        .allowsHitTesting(!isLoading)
    }
}

public struct RelaySecondaryCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public let height: CGFloat
    public let isLoading: Bool
    public init(height: CGFloat = RelayVisualStyle.buttonHeight, isLoading: Bool = false) {
        self.height = height; self.isLoading = isLoading
    }
    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            if isLoading { ProgressView().controlSize(.small); Text("处理中…") }
            else { configuration.label }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(configuration.role == .destructive ? Color.red : Color.accentColor)
        .padding(.horizontal, 13)
        .frame(minHeight: height)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay { Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false) }
        .contentShape(Capsule())
        .brightness(configuration.isPressed ? -0.05 : 0)
        .opacity(isEnabled || isLoading ? 1 : 0.4)
        .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
        .animation(configuration.isPressed || reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1), value: configuration.isPressed)
        .allowsHitTesting(!isLoading)
    }
}

public struct RelayCircularIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    public let diameter: CGFloat
    public let isSelected: Bool
    public init(diameter: CGFloat = RelayVisualStyle.iconButtonDiameter, isSelected: Bool = false) {
        self.diameter = diameter; self.isSelected = isSelected
    }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: diameter, height: diameter)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.04), in: Circle())
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Rows give local feedback without scaling the surrounding list or typography.
public struct RelayCardButtonStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: RelayVisualStyle.radiusCard))
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.09 : 0),
                        in: RoundedRectangle(cornerRadius: RelayVisualStyle.radiusCard))
    }
}

public struct RelayTextButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(configuration.role == .destructive ? Color.red : Color.accentColor)
            .padding(.horizontal, 6)
            .frame(minHeight: RelayVisualStyle.buttonHeight)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.1 : 0), in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

private struct RelayInputSurfaceModifier: ViewModifier {
    let isFocused: Bool
    let cornerRadius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(isFocused ? Color.accentColor : Color.primary.opacity(contrast == .increased ? 0.45 : 0.1),
                                  lineWidth: isFocused ? 2 : 0.5)
                    .allowsHitTesting(false)
            }
    }
}

private struct RelayFormFieldModifier: ViewModifier {
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain)
            .font(.system(size: RelayVisualStyle.bodyFontSize))
            .focused($isFocused)
            .padding(.horizontal, 10)
            .frame(minHeight: RelayVisualStyle.inputHeight)
            .modifier(RelayInputSurfaceModifier(isFocused: isFocused, cornerRadius: RelayVisualStyle.radiusSmall))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

struct RelaySearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索站点或账户", text: $text)
                .textFieldStyle(.plain).focused($isFocused)
                .accessibilityLabel("搜索账户、站点、服务商或分组")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark") }
                    .buttonStyle(RelayCircularIconButtonStyle(diameter: 20))
                    .accessibilityLabel("清除搜索")
            }
        }
        .font(.system(size: 12)).padding(.horizontal, 10)
        .frame(height: RelayVisualStyle.inputHeight)
        .modifier(RelayInputSurfaceModifier(isFocused: isFocused, cornerRadius: 10))
    }
}

struct RelayProviderIcon: View {
    let kind: ProviderKind
    var size: CGFloat = 34
    private var color: Color {
        switch kind {
        case .deepseek: return Color(red: 0.30, green: 0.42, blue: 0.91)
        case .pipio: return Color(red: 0.23, green: 0.44, blue: 0.35)
        default: return .secondary
        }
    }
    var body: some View {
        Group {
            switch kind {
            case .deepseek:
                Canvas { context, bounds in
                    let coordinates: [(CGFloat, CGFloat)] = [(6,19),(7,12),(13,10),(19,12),(24,17),(29,12),(28,21),(24,24),(15,24),(10,22)]
                    let points = coordinates.map { CGPoint(x: $0.0 / 34 * bounds.width, y: $0.1 / 34 * bounds.height) }
                    var path = Path(); path.addLines(points); path.closeSubpath()
                    context.fill(path, with: .color(color))
                    context.fill(Path(ellipseIn: CGRect(x: bounds.width * 12 / 34, y: bounds.height * 15 / 34,
                        width: bounds.width * 1.5 / 34, height: bounds.height * 1.5 / 34)), with: .color(.white))
                }
            case .pipio:
                Text("P").font(.system(size: size * 0.56, weight: .semibold)).foregroundStyle(color)
            default:
                Image(systemName: kind == .workbuddy2api ? "bolt.fill" : "network")
                    .font(.system(size: size * 0.48, weight: .medium)).foregroundStyle(color)
            }
        }
            .frame(width: size, height: size)
            .background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: size * 0.3))
            .accessibilityHidden(true)
    }
}

public extension View {
    func relayPanelSurface(cornerRadius: CGFloat = RelayVisualStyle.panelCornerRadius) -> some View {
        modifier(RelaySurface(kind: .panel, cornerRadius: cornerRadius)).relayInitialFocus()
    }
    func relayGlassTile(cornerRadius: CGFloat = RelayVisualStyle.cardCornerRadius) -> some View {
        modifier(RelaySurface(kind: .content, cornerRadius: cornerRadius))
    }
    func relayInsetSurface(cornerRadius: CGFloat = RelayVisualStyle.radiusSmall) -> some View {
        modifier(RelaySurface(kind: .inset, cornerRadius: cornerRadius))
    }
    func relayFloatingBarSurface(cornerRadius: CGFloat = RelayVisualStyle.radiusFAB) -> some View {
        modifier(RelaySurface(kind: .toolbar, cornerRadius: cornerRadius))
    }
    func relayFormField() -> some View { modifier(RelayFormFieldModifier()) }
}
