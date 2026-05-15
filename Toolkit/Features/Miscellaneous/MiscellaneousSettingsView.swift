import SwiftUI

struct MiscellaneousSettingsView: View {
    @ObservedObject var bootstrapper: AppBootstrapper

    private var feature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "miscellaneous" })
    }

    var body: some View {
        SettingsPage(
            eyebrow: "Feature",
            title: "Miscellaneous",
            subtitle: "System-level helper behaviors that do not fit into a dedicated toolkit module."
        ) {
            featureToggle
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsRow(
                            "Reverse mouse scroll",
                            description: "When a physical mouse is connected, use reversed scroll direction. Your original system setting is restored when the mouse disconnects or this feature is disabled."
                        ) {
                            Toggle("", isOn: $bootstrapper.reversePhysicalMouseScrollEnabled)
                                .labelsHidden()
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
