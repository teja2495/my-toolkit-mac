import SwiftUI

struct WindowShortcutsSettingsView: View {
    @ObservedObject var bootstrapper: AppBootstrapper

    private var feature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "window-shortcuts" })
    }

    private var permissionGranted: Bool {
        bootstrapper.accessibilityPermissionManager.isTrusted
    }

    var body: some View {
        SettingsPage(
            eyebrow: "Feature",
            title: "Keyboard Shortcuts",
            subtitle: "Global shortcuts that snap the focused window of any app restart, quit or force quit the focused app, put the computer to sleep, or open Enpass."
        ) {
            if let feature {
                FeatureEnableToggle(isOn: feature.isEnabled, disabled: !permissionGranted) {
                    bootstrapper.toggleFeature(id: feature.id)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                if !permissionGranted {
                    PermissionRequiredBanner(bootstrapper: bootstrapper)
                }

                SettingsCard {
                    VStack(alignment: .leading, spacing: 0) {
                        let placements = WindowShortcutsFeature.Placement.allCases
                        ForEach(Array(placements.enumerated()), id: \.offset) { index, placement in
                            if index > 0 {
                                SettingsCardDivider()
                            }
                            SettingsRow(placement.title) {
                                ShortcutBadge(symbol: placement.symbol)
                            }
                        }
                    }
                }

                SettingsCard {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsRow(WindowShortcutsFeature.restartAppShortcutTitle) {
                            ShortcutBadge(symbol: WindowShortcutsFeature.restartAppShortcutSymbol)
                        }
                        SettingsCardDivider()
                        SettingsRow(WindowShortcutsFeature.quitAppShortcutTitle) {
                            ShortcutBadge(symbol: WindowShortcutsFeature.quitAppShortcutSymbol)
                        }
                        SettingsCardDivider()
                        SettingsRow(WindowShortcutsFeature.forceQuitAppShortcutTitle) {
                            ShortcutBadge(symbol: WindowShortcutsFeature.forceQuitAppShortcutSymbol)
                        }
                        SettingsCardDivider()
                        SettingsRow(WindowShortcutsFeature.sleepShortcutTitle) {
                            ShortcutBadge(symbol: WindowShortcutsFeature.sleepShortcutSymbol)
                        }
                        SettingsCardDivider()
                        SettingsRow(WindowShortcutsFeature.openEnpassShortcutTitle) {
                            ShortcutBadge(symbol: WindowShortcutsFeature.openEnpassShortcutSymbol)
                        }
                    }
                }
            }
        }
    }
}

private struct ShortcutBadge: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(0.12))
            )
    }
}
