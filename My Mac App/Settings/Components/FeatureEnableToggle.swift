import SwiftUI

struct FeatureEnableToggle: View {
    let isOn: Bool
    let disabled: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isOn ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)

                Text(isOn ? "Enabled" : "Disabled")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(isOn ? Color.primary : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .help(disabled
              ? "Grant accessibility access to enable this feature"
              : (isOn ? "Click to disable" : "Click to enable"))
    }
}
