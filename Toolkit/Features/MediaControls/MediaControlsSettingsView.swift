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
            subtitle: "Shows playback controls at the top center of the display."
        ) {
            featureToggle
        } content: {
            SettingsCard {
                SettingsRow(
                    "Playback controls",
                    description: "On notched displays, hover the top-center area to open controls. On non-notch displays, controls appear inline in the menu bar with album art, previous, play or pause, and next."
                ) {
                    Image(systemName: "music.note")
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
