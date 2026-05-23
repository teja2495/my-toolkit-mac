import SwiftUI

struct MediaControlsSettingsView: View {
    @ObservedObject var bootstrapper: AppBootstrapper

    private var feature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "media-controls" })
    }

    var body: some View {
        SettingsPage(
            eyebrow: "Feature",
            title: "Media Controls",
            subtitle: "Shows a pause button in the menu bar while media is playing, and opens playback controls when the cursor enters the notch area."
        ) {
            featureToggle
        } content: {
            SettingsCard {
                SettingsRow(
                    "Playback controls",
                    description: "Hover the menu bar item or the top-center notch area to open artwork, timeline, previous, pause or play, and next controls."
                ) {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
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
