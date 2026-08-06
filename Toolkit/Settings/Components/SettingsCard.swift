import SwiftUI

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsSurface(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension View {
    /// Solid surface used for settings cards and pill buttons.
    func settingsSurface<S: InsettableShape>(_ shape: S, emphasized: Bool = false) -> some View {
        self
            .background(shape.fill(emphasized ? Color.settingsSurfaceStrong : Color.settingsSurface))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }
}

extension Color {
    /// Card fill: slightly raised against the window background in both appearances.
    static let settingsSurface = Color(nsColor: .appearanceAware(
        light: NSColor(white: 1, alpha: 0.75),
        dark: NSColor(white: 1, alpha: 0.07)
    ))

    /// Stronger variant for controls that sit on top of a card.
    static let settingsSurfaceStrong = Color(nsColor: .appearanceAware(
        light: NSColor(white: 1, alpha: 1),
        dark: NSColor(white: 1, alpha: 0.12)
    ))

    /// Sidebar backdrop: recessed against the window background.
    static let settingsSidebarBackground = Color(nsColor: .appearanceAware(
        light: NSColor(white: 0, alpha: 0.04),
        dark: NSColor(white: 0, alpha: 0.12)
    ))
}

extension NSColor {
    static func appearanceAware(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

struct SettingsCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
            .padding(.vertical, 14)
    }
}
