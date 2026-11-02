import SwiftUI

/// Apple Design expressed through native macOS surfaces and semantic colors.
/// Material belongs to the outer chrome; content stays on quiet, readable surfaces.
public enum RelayVisualStyle {
    public static let panelWidth: CGFloat = 420
    public static let panelHeight: CGFloat = 660
    public static let detailPanelWidth: CGFloat = 760
    public static let detailPanelHeight: CGFloat = 700
    public static let formPanelWidth: CGFloat = 520
    public static let formPanelHeight: CGFloat = 660
    public static let settingsPanelWidth: CGFloat = 540
    public static let settingsPanelHeight: CGFloat = 680
    public static let auxiliaryPanelCornerRadius: CGFloat = 22
    public static let buttonHeight: CGFloat = 32
    public static let iconButtonDiameter: CGFloat = 30
    public static let inputHeight: CGFloat = 34
    public static let navigationHeight: CGFloat = 40
    public static let buttonFontSize: CGFloat = 12
    public static let bodyFontSize: CGFloat = 13
    public static let radiusSmall: CGFloat = 8
    public static let radiusMedium: CGFloat = 10
    public static let radiusCard: CGFloat = 13
    public static let radiusPanel: CGFloat = 22
    public static let radiusLarge: CGFloat = 24
    public static let radiusFAB: CGFloat = 16
    public static let cardCornerRadius: CGFloat = radiusCard
    public static let panelCornerRadius: CGFloat = radiusPanel
    public static let spacingTight: CGFloat = 8
    public static let spacingStandard: CGFloat = 16
    public static let spacingSection: CGFloat = 22
    public static let spacingLoose: CGFloat = 28
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
                            .overlay { shape.fill((scheme == .dark ? Color.black : Color.white).opacity(kind == .panel ? 0.23 : 0.12)) }
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
    private var symbol: String {
        switch kind {
        case .deepseek: return "water.waves"
        case .pipio: return "p.square.fill"
        case .workbuddy2api: return "bolt.fill"
        case .custom: return "network"
        }
    }
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(kind == .workbuddy2api ? Color.secondary : .accentColor)
            .frame(width: size, height: size)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: size * 0.3))
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
