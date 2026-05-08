import SwiftUI

struct CornerNotesSettingsView: View {
    @ObservedObject var bootstrapper: AppBootstrapper

    private var feature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "corner-notes" })
    }

    var body: some View {
        SettingsPage(
            eyebrow: "Feature",
            title: "Quick Notes",
            subtitle: "A two-pane todo and notebook that opens from the bottom-right hot corner."
        ) {
            featureToggle
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsRow(
                            "Hot corner",
                            description: "Move the cursor into the bottom-right corner to toggle the panel."
                        ) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.right.square")
                                    .font(.system(size: 11))
                                Text("Bottom-right")
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(Color.primary.opacity(0.05))
                            )
                        }

                        SettingsCardDivider()

                        SettingsRow(
                            "Permissions",
                            description: "No accessibility access needed — uses cursor position only."
                        ) {
                            Text("None required")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.green)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(Color.green.opacity(0.12))
                                )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var featureToggle: some View {
        if let feature {
            FeatureEnableToggle(
                isOn: feature.isEnabled,
                disabled: false
            ) {
                bootstrapper.toggleFeature(id: feature.id)
            }
        }
    }
}
