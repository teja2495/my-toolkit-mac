import SwiftUI

extension View {
    /// Neutral keycap look for keyboard shortcuts and typed triggers.
    /// Use `monospaced` for user-typed text (abbreviations, trigger words); leave it off for ⌘⌥⇧ symbols.
    func keycapStyle(monospaced: Bool = false) -> some View {
        modifier(KeycapStyle(monospaced: monospaced))
    }
}

private struct KeycapStyle: ViewModifier {
    let monospaced: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

        content
            .font(.system(size: 12, weight: .medium, design: monospaced ? .monospaced : .default))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(shape.fill(Color.settingsSurfaceStrong))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 0, x: 0, y: 1)
    }
}
