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

private struct RelayPanelSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
        .opacity(isEnabled ? (isPressed ? 0.95 : 1.0) : 0.3)
        .scaleEffect(isPressed && isEnabled ? 0.96 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPressed)
    }
}

/// Secondary frosted glass capsule button (48~52dp, backdrop blur + 1px subtle stroke).
public struct RelaySecondaryCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    public let height: CGFloat

    public init(height: CGFloat = 48) {
        self.height = height
    }

    public func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed

        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(.thinMaterial, in: Capsule())
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
            .opacity(isEnabled ? (isPressed ? 0.92 : 1.0) : 0.3)
            .scaleEffect(isPressed && isEnabled ? 0.96 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPressed)
    }
}

/// 40~44dp circular icon button with linear styling and press feedback.
public struct RelayCircularIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    public let diameter: CGFloat
    public let isSelected: Bool

    public init(diameter: CGFloat = 42, isSelected: Bool = false) {
        self.diameter = diameter
        self.isSelected = isSelected
    }

    public func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed

        configuration.label
            .font(.system(size: 18, weight: .medium))
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
            .scaleEffect(isPressed && isEnabled ? 0.94 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
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
}
