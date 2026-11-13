import SwiftUI

struct ClipboardHistorySettingsView: View {
    @ObservedObject var bootstrapper: AppBootstrapper

    private var feature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "clipboard-history" })
    }

    var body: some View {
        SettingsPage(
            title: "Clipboard History",
            subtitle: "Keeps every text and image you copy. Open the history to browse, preview, and paste past items.",
            systemImage: "doc.on.clipboard",
            isActive: feature?.isEnabled
        ) {
            if let feature {
                FeatureEnableToggle(isOn: feature.isEnabled, disabled: false) {
                    bootstrapper.toggleFeature(id: feature.id)
                }
            }
        } content: {
            SettingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsRow(
                        "Open history",
                        description: "Global shortcut that shows the clipboard history window."
                    ) {
                        Text(ClipboardHistoryFeature.triggerSymbol)
                            .keycapStyle()
                    }

                    SettingsCardDivider()

                    SettingsRow(
                        "Show now",
                        description: "Use ↑ ↓ to move, Return to copy, ⌘Return to paste into the previous app, Delete to remove, Esc to close. Right-click an item to pin it. Up to \(ClipboardHistoryStore.maxItems) items are kept; the oldest unpinned item is dropped first. Password manager copies are skipped."
                    ) {
                        Button("Open") {
                            bootstrapper.showClipboardHistory()
                        }
                        .controlSize(.small)
                        .disabled(feature?.isEnabled != true)
                    }
                }
            }
        }
    }
}
