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
            VStack(alignment: .leading, spacing: 16) {
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

                SettingsCard {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsRow(
                            "Popup delay",
                            description: "Time the cursor must rest over the notch area before the controls appear."
                        ) {
                            Text("\(Int((bootstrapper.mediaControlsHoverDelay * 1000).rounded())) ms")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(Color.primary.opacity(0.05))
                                )
                                .frame(minWidth: 64)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Slider(
                                value: $bootstrapper.mediaControlsHoverDelay,
                                in: 0...2.0,
                                step: 0.05
                            )
                            .tint(Color.accentColor)
                            .padding(.top, 12)

                            HStack {
                                Text("Instant")
                                    .font(.system(size: 9, weight: .medium))
                                    .tracking(0.6)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Text("2.0s")
                                    .font(.system(size: 9, weight: .medium))
                                    .tracking(0.6)
                                    .foregroundStyle(.tertiary)
                            }
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
