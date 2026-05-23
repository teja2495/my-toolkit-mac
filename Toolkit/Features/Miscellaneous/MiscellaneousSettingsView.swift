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
                        SettingsRow(
                            mediaControlsFeature.title,
                            description: mediaControlsFeature.summary
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
