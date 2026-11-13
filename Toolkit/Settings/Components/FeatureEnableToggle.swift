import SwiftUI

struct FeatureEnableToggle: View {
    let isOn: Bool
    let disabled: Bool
    var disabledHelp: String = "Grant accessibility access to enable this feature"
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 7) {
                Image(systemName: "power")
                    .font(.system(size: 10, weight: .bold))
                Text(isOn ? "On" : "Off")
            }
            .frame(minWidth: 44)
        }
        .buttonStyle(SettingsPillButtonStyle(isActive: isOn))
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .help(disabled
              ? disabledHelp
              : (isOn ? "Turn off" : "Turn on"))
        .accessibilityLabel(isOn ? "Feature on" : "Feature off")
    }
}
