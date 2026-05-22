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
            SettingsCard {
                Text("No miscellaneous settings yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
