import SwiftUI

/// Shared visual language for Relay's dashboard and auxiliary pages.
///
/// The surfaces intentionally use SwiftUI's native macOS materials instead of
/// reproducing blur/glass with custom gradients or filters. This keeps the
/// appearance adaptive to the system appearance, wallpaper, vibrancy and
/// accessibility settings while sharing one visual vocabulary across pages.
public enum RelayVisualStyle {
    /// Shared width for the main popover and auxiliary panels.
    public static let panelWidth: CGFloat = 360
    public static let panelCornerRadius: CGFloat = 20
    public static let cardCornerRadius: CGFloat = 12
    public static let auxiliaryPanelCornerRadius: CGFloat = 18

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

private struct RelayPanelSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.48), lineWidth: 0.8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.11), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.10), radius: 16, y: 8)
    }
}

private struct RelayGlassTileModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.52), lineWidth: 0.75)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 0.7)
            }
    }
}

private struct RelayInsetSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 0.7)
            }
    }
}

public extension View {
    /// Native material container used by the main dashboard and auxiliary pages.
    func relayPanelSurface(cornerRadius: CGFloat = RelayVisualStyle.panelCornerRadius) -> some View {
        modifier(RelayPanelSurfaceModifier(cornerRadius: cornerRadius))
    }

    /// Native material card used for summary, metric and account tiles.
    func relayGlassTile(cornerRadius: CGFloat = RelayVisualStyle.cardCornerRadius) -> some View {
        modifier(RelayGlassTileModifier(cornerRadius: cornerRadius))
    }

    /// Subtle nested surface for content that sits inside a glass card.
    func relayInsetSurface(cornerRadius: CGFloat = 10) -> some View {
        modifier(RelayInsetSurfaceModifier(cornerRadius: cornerRadius))
    }
}
