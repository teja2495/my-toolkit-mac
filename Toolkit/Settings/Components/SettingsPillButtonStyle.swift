import SwiftUI

/// Capsule button used in page headers. `isActive` tints it green to show something is on.
struct SettingsPillButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isActive ? Color.green : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isActive ? Color.green.opacity(0.16) : Color.settingsSurfaceStrong)
            )
            .overlay(
                Capsule().strokeBorder(isActive ? Color.green.opacity(0.4) : Color.primary.opacity(0.1), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
