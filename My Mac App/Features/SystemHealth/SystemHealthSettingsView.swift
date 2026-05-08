import SwiftUI

struct SystemHealthSettingsView: View {
    @ObservedObject var bootstrapper: AppBootstrapper

    private var feature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "system-health" })
    }

    var body: some View {
        SettingsPage(
            eyebrow: "Feature",
            title: "System Health",
            subtitle: "Shows a small menu bar dot that turns amber when CPU, memory, disk, or battery needs attention."
        ) {
            featureToggle
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsRow(
                            "Menu bar indicator",
                            description: "A green dot means system usage is within normal limits. Amber means at least one metric needs attention."
                        ) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 7, height: 7)
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 7, height: 7)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                        }

                        SettingsCardDivider()

                        SettingsRow(
                            "Popup metrics",
                            description: "Click the dot to see CPU usage, memory usage, memory pressure, disk usage, battery level, and swap usage."
                        ) {
                            Image(systemName: "chart.bar.xaxis")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        SettingsCardDivider()

                        SettingsRow(
                            "Permissions",
                            description: "No accessibility access needed. Metrics are read locally from macOS system APIs."
                        ) {
                            Text("None required")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.green)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.green.opacity(0.12)))
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
