import SwiftUI

/// Shared visual language for Relay's dashboard, modals, and auxiliary panels.
///
/// Blends HyperOS clean restraint with iOS system-level frosted glassmorphism.
/// Leverages native macOS vibrant materials (`.regularMaterial`, `.thinMaterial`,
/// `.ultraThinMaterial`) paired with continuous rounded corners, 0.5~1px hairline strokes,
/// and soft diffusion shadows.
public enum RelayVisualStyle {
    // MARK: - Layout & Dimension Tokens
    /// Shared width for the main popover and auxiliary panels.
    public static let panelWidth: CGFloat = 360
    public static let auxiliaryPanelCornerRadius: CGFloat = 20

    // MARK: - Radius Ladder (8 / 12~16 / 20~24 / Capsule)
    public static let radiusSmall: CGFloat = 8
    public static let radiusMedium: CGFloat = 14
    public static let radiusCard: CGFloat = 16
    public static let radiusPanel: CGFloat = 20
    public static let radiusLarge: CGFloat = 24
    public static let radiusFAB: CGFloat = 28

    /// Preserved alias for card corner radius across existing components.
    public static let cardCornerRadius: CGFloat = radiusCard
    /// Preserved alias for main panel corner radius.
    public static let panelCornerRadius: CGFloat = radiusPanel

    // MARK: - Grid Spacing Tokens (8dp Grid)
    public static let spacingTight: CGFloat = 8
    public static let spacingStandard: CGFloat = 16
    public static let spacingSection: CGFloat = 24
    public static let spacingLoose: CGFloat = 32

    // MARK: - Colors & Accents
    public static let accentColor: Color = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255) // #0A84FF
    public static let destructiveColor: Color = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255) // #FF453A
    public static let darkCardColor = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)

    /// One app-wide appearance policy for the dashboard and every auxiliary page.
    /// A manual light/dark choice must win over the system appearance, while
    /// followSystem keeps the native macOS behavior intact.
    public static func preferredColorScheme(for mode: AppearanceMode) -> ColorScheme? {
        switch mode {
        case .followSystem: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Surface Modifiers

/// Keep native vibrancy, with predictable light/dark contrast and an opaque
/// fallback when the user enables Reduce Transparency.
private struct RelayMaterialBackground: View {
    let material: Material
    let cornerRadius: CGFloat
    let lightOpacity: Double
    let darkOpacity: Double
    var isPanel = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let color = colorScheme == .dark
            ? (isPanel ? Color.black : RelayVisualStyle.darkCardColor) : .white
        if reduceTransparency {
            shape.fill(color)
        } else {
            shape.fill(material)
                .overlay { shape.fill(color.opacity(colorScheme == .dark ? darkOpacity : lightOpacity)) }
        }
    }
}

private struct RelayPanelSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                RelayMaterialBackground(material: .regularMaterial, cornerRadius: cornerRadius,
                                        lightOpacity: 0.45, darkOpacity: 0.6, isPanel: true)
            }
            .tint(RelayVisualStyle.accentColor)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.55),
                        lineWidth: 0.8
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.08), lineWidth: 0.5)
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08),
                radius: 18,
                x: 0,
                y: 8
            )
    }
}

private struct RelayGlassTileModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                RelayMaterialBackground(material: .thinMaterial, cornerRadius: cornerRadius,
                                        lightOpacity: 0.78, darkOpacity: 0.8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.60),
                        lineWidth: 0.75
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.20 : 0.06), lineWidth: 0.5)
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.04),
                radius: 8,
                x: 0,
                y: 2
            )
    }
}

private struct RelayInsetSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.08) : Color.primary.opacity(0.08),
                        lineWidth: 0.5
                    )
            }
    }
}

private struct RelayFloatingBarModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                RelayMaterialBackground(material: .regularMaterial, cornerRadius: cornerRadius,
                                        lightOpacity: 0.8, darkOpacity: 0.8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.75),
                        lineWidth: 1.0
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.25 : 0.08), lineWidth: 0.5)
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.40 : 0.12),
                radius: 20,
                x: 0,
                y: 10
            )
    }
}

// MARK: - Capsule & Interactive Button Styles

/// Primary pill capsule button (48~52dp, inverted monochrome, 96% spring scale on press).
public struct RelayPrimaryCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public let height: CGFloat
    public let isLoading: Bool

    public init(height: CGFloat = 48, isLoading: Bool = false) {
        self.height = height
        self.isLoading = isLoading
    }

    public func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed
        let backgroundFill = colorScheme == .dark ? Color.white : Color.black
        let foreground = colorScheme == .dark ? Color.black : Color.white

        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(foreground)
                Text("处理中…")
            } else {
                configuration.label
            }
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundColor(foreground)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(backgroundFill)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .overlay { Capsule().fill(Color.black.opacity(isPressed && isEnabled ? 0.05 : 0)).allowsHitTesting(false) }
        .opacity(isEnabled || isLoading ? 1 : 0.3)
        .scaleEffect(isPressed && isEnabled && !reduceMotion ? 0.96 : 1.0)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 1), value: isPressed)
        .allowsHitTesting(!isLoading)
    }
}

/// Secondary frosted glass capsule button (48~52dp, backdrop blur + 1px subtle stroke).
public struct RelaySecondaryCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public let height: CGFloat
    public let isLoading: Bool

    public init(height: CGFloat = 48, isLoading: Bool = false) {
        self.height = height
        self.isLoading = isLoading
    }

    public func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed

        HStack(spacing: 8) {
            if isLoading {
                ProgressView().controlSize(.small)
                Text("处理中…")
            } else {
                configuration.label
            }
        }
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(configuration.role == .destructive ? RelayVisualStyle.destructiveColor : .primary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background {
                RelayMaterialBackground(material: .thinMaterial, cornerRadius: height / 2,
                                        lightOpacity: 0.8, darkOpacity: 0.08)
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.70),
                        lineWidth: 1
                    )
            }
            .overlay {
                Capsule()
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.20 : 0.08), lineWidth: 0.5)
            }
            .contentShape(Capsule())
            .opacity(isEnabled || isLoading ? (isPressed ? 0.95 : 1) : 0.3)
            .scaleEffect(isPressed && isEnabled && !reduceMotion ? 0.96 : 1.0)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 1), value: isPressed)
            .allowsHitTesting(!isLoading)
    }
}

/// 40~44dp circular icon button with linear styling and press feedback.
public struct RelayCircularIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public let diameter: CGFloat
    public let isSelected: Bool

    public init(diameter: CGFloat = 42, isSelected: Bool = false) {
        self.diameter = diameter
        self.isSelected = isSelected
    }

    public func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed

        configuration.label
            .font(.system(size: 18, weight: .regular))
            .symbolVariant(isSelected ? .fill : .none)
            .foregroundColor(isSelected ? RelayVisualStyle.accentColor : .primary)
            .frame(width: diameter, height: diameter)
            .background(
                Circle()
                    .fill(isPressed ? Color.primary.opacity(0.10) : (isSelected ? RelayVisualStyle.accentColor.opacity(0.12) : Color.clear))
            )
            .overlay {
                Circle()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .opacity(isEnabled ? 1.0 : 0.3)
            .contentShape(Circle())
            .scaleEffect(isPressed && isEnabled && !reduceMotion ? 0.96 : 1.0)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1), value: isPressed)
    }
}

public struct RelayCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: RelayVisualStyle.radiusCard))
            .brightness(configuration.isPressed ? -0.03 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1), value: configuration.isPressed)
    }
}

public struct RelayTextButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(configuration.role == .destructive ? RelayVisualStyle.destructiveColor : RelayVisualStyle.accentColor)
            .padding(.horizontal, 8)
            .frame(minHeight: 40)
            .background(configuration.isPressed ? RelayVisualStyle.accentColor.opacity(0.1) : .clear, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.3)
    }
}

private struct RelayInputSurfaceModifier: ViewModifier {
    let isFocused: Bool
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(Color(red: 118 / 255, green: 118 / 255, blue: 128 / 255)
                .opacity(colorScheme == .dark ? 0.24 : 0.12), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(isFocused ? RelayVisualStyle.accentColor : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
    }
}

private struct RelayFormFieldModifier: ViewModifier {
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($isFocused)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .modifier(RelayInputSurfaceModifier(isFocused: isFocused, cornerRadius: 12))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

struct RelaySearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索账号", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .accessibilityLabel("搜索账号、服务商或分组")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark") }
                    .buttonStyle(RelayCircularIconButtonStyle(diameter: 24))
                    .accessibilityLabel("清除搜索")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(height: 40)
        .modifier(RelayInputSurfaceModifier(isFocused: isFocused, cornerRadius: 20))
    }
}

// MARK: - View Extensions

public extension View {
    /// Native material container used by the main dashboard and auxiliary pages.
    func relayPanelSurface(cornerRadius: CGFloat = RelayVisualStyle.panelCornerRadius) -> some View {
        modifier(RelayPanelSurfaceModifier(cornerRadius: cornerRadius)).relayInitialFocus()
    }

    /// Native material card used for summary, metric and account tiles.
    func relayGlassTile(cornerRadius: CGFloat = RelayVisualStyle.cardCornerRadius) -> some View {
        modifier(RelayGlassTileModifier(cornerRadius: cornerRadius))
    }

    /// Subtle nested surface for content that sits inside a glass card.
    func relayInsetSurface(cornerRadius: CGFloat = RelayVisualStyle.radiusSmall) -> some View {
        modifier(RelayInsetSurfaceModifier(cornerRadius: cornerRadius))
    }

    /// Floating Action Bar (FAB) container with soft diffusion shadow and frosted glass background.
    func relayFloatingBarSurface(cornerRadius: CGFloat = RelayVisualStyle.radiusFAB) -> some View {
        modifier(RelayFloatingBarModifier(cornerRadius: cornerRadius))
    }

    func relayFormField() -> some View {
        modifier(RelayFormFieldModifier())
    }
}
