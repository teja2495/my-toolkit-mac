import SwiftUI

struct MiscellaneousSettingsView: View {
    @ObservedObject var bootstrapper: AppBootstrapper

    private var feature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "miscellaneous" })
    }

    private var quickNotesFeature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "corner-notes" })
    }

    private var systemHealthFeature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "system-health" })
    }

    private var mediaControlsFeature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "media-controls" })
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
                VStack(alignment: .leading, spacing: 0) {
                    if let quickNotesFeature {
                        SettingsRow(
                            quickNotesFeature.title,
                            description: quickNotesFeature.summary
                        ) {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { quickNotesFeature.isEnabled },
                                    set: { _ in
                                        bootstrapper.toggleFeature(id: quickNotesFeature.id)
                                    }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }

                    if quickNotesFeature != nil, systemHealthFeature != nil {
                        SettingsCardDivider()
                    }

                    if let systemHealthFeature {
                        SettingsRow(
                            systemHealthFeature.title,
                            description: systemHealthFeature.summary
                        ) {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { systemHealthFeature.isEnabled },
                                    set: { _ in
                                        bootstrapper.toggleFeature(id: systemHealthFeature.id)
                                    }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }

                    if systemHealthFeature != nil, mediaControlsFeature != nil {
                        SettingsCardDivider()
                    }

                    if let mediaControlsFeature {
                        VStack(alignment: .leading, spacing: 6) {
                            let isMediaControlsEnabled = mediaControlsFeature.isEnabled

                            SettingsRow(
                                mediaControlsFeature.title,
                                description: isMediaControlsEnabled ? "" : mediaControlsFeature.summary
                            ) {
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { mediaControlsFeature.isEnabled },
                                        set: { _ in
                                            bootstrapper.toggleFeature(id: mediaControlsFeature.id)
                                        }
                                    )
                                )
                                .labelsHidden()
                                .toggleStyle(.switch)
                            }

                            if isMediaControlsEnabled {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Slider(
                                            value: $bootstrapper.mediaControlsHoverDelay,
                                            in: 0...2.0,
                                            step: 0.05
                                        )
                                        .tint(Color.accentColor)

                                        Text("\(Int((bootstrapper.mediaControlsHoverDelay * 1000).rounded())) ms")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(
                                                Capsule().fill(Color.primary.opacity(0.05))
                                            )
                                            .frame(minWidth: 74, alignment: .trailing)
                                    }

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
                                .frame(maxWidth: 360)
                                .padding(.top, -10)
                                .padding(.leading, 1)
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
