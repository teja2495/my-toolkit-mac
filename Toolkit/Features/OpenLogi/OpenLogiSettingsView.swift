import SwiftUI

struct OpenLogiSettingsView: View {
    @ObservedObject var bootstrapper: AppBootstrapper

    private var feature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "openlogi" })
    }

    private var permissionGranted: Bool {
        bootstrapper.accessibilityPermissionManager.isTrusted
    }

    var body: some View {
        SettingsPage(
            eyebrow: "Feature",
            title: "OpenLogi",
            subtitle: "Customize what your mouse buttons do, inspired by the OpenLogi project."
        ) {
            featureToggle
        } content: {
            SettingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(OpenLogiButton.allCases.enumerated()), id: \.element) { index, button in
                        if index > 0 {
                            SettingsCardDivider()
                        }
                        SettingsRow(button.title, description: button.description) {
                            VStack(alignment: .trailing, spacing: 6) {
                                labeledPicker(
                                    "Click",
                                    actions: MouseButtonAction.singleClickActions,
                                    selection: binding(for: button, in: \.openLogiButtonActions)
                                )
                                labeledPicker(
                                    "Double-click",
                                    actions: MouseButtonAction.doubleClickActions,
                                    selection: binding(for: button, in: \.openLogiDoubleClickActions)
                                )
                            }
                        }
                    }
                }
            }
            .disabled(!permissionGranted)
        }
    }

    private func binding(
        for button: OpenLogiButton,
        in keyPath: ReferenceWritableKeyPath<AppBootstrapper, [OpenLogiButton: MouseButtonAction]>
    ) -> Binding<MouseButtonAction> {
        Binding(
            get: { bootstrapper[keyPath: keyPath][button] ?? .systemDefault },
            set: { bootstrapper[keyPath: keyPath][button] = $0 }
        )
    }

    private func labeledPicker(
        _ label: String,
        actions: [MouseButtonAction],
        selection: Binding<MouseButtonAction>
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(actions) { action in
                    Text(action.title).tag(action)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 180)
        }
    }

    @ViewBuilder
    private var featureToggle: some View {
        if let feature {
            FeatureEnableToggle(
                isOn: feature.isEnabled,
                disabled: !permissionGranted
            ) {
                bootstrapper.toggleFeature(id: feature.id)
            }
        }
    }
}
