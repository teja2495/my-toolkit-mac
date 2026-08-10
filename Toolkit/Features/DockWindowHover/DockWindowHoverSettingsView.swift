import AppKit
import SwiftUI

struct DockWindowHoverSettingsView: View {
    @ObservedObject var bootstrapper: AppBootstrapper

    private var feature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "dock-window-hover" })
    }

    private var permissionGranted: Bool {
        bootstrapper.accessibilityPermissionManager.isTrusted
    }

    var body: some View {
        SettingsPage(
            eyebrow: "Feature",
            title: "App Windows",
            subtitle: "Hover an app icon in the Dock to peek at its open windows by title."
        ) {
            featureToggle
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                if !permissionGranted {
                    PermissionRequiredBanner(bootstrapper: bootstrapper)
                }

                SettingsCard {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsRow(
                            "Popup delay",
                            description: "Time the cursor must rest on a Dock icon before the popup appears."
                        ) {
                            Text("\(Int((bootstrapper.dockHoverPopupDelay * 1000).rounded())) ms")
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
                                value: $bootstrapper.dockHoverPopupDelay,
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

                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Tip")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Right-click a Dock icon to suppress the popup for that app until you move away — useful when you want the system context menu instead.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("For VS Code, search folders in the popup and right-click a result to pin it. Right-click a pinned folder to unpin.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
                disabled: !permissionGranted
            ) {
                bootstrapper.toggleFeature(id: feature.id)
            }
        }
    }
}

struct PermissionRequiredBanner: View {
    @ObservedObject var bootstrapper: AppBootstrapper

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility access required")
                    .font(.system(size: 12, weight: .semibold))
                Text("Grant access to enable this feature.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button {
                bootstrapper.requestAccessibilityAccess()
            } label: {
                Text("Grant")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Color.orange)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.settingsSurface)
            )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }
}
