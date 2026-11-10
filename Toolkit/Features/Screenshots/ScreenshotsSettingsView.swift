import SwiftUI

struct ScreenshotsSettingsView: View {
    @ObservedObject var bootstrapper: AppBootstrapper

    private var feature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "screenshots" })
    }

    private var permissionGranted: Bool {
        bootstrapper.screenRecordingPermissionManager.isGranted
    }

    var body: some View {
        SettingsPage(
            eyebrow: "Feature",
            title: "Screenshots",
            subtitle: "Select an area of the screen to copy it to the clipboard, then save it, open it in Preview, or capture the full screen instead."
        ) {
            if let feature {
                FeatureEnableToggle(
                    isOn: feature.isEnabled && permissionGranted,
                    disabled: !permissionGranted,
                    disabledHelp: "Grant Screen Recording access to enable this feature"
                ) {
                    bootstrapper.toggleFeature(id: feature.id)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                if !permissionGranted {
                    ScreenRecordingPermissionBanner(bootstrapper: bootstrapper)
                }

                SettingsCard {
                    SettingsRow(
                        "Capture area",
                        description: "Drag to select an area. Press Space to pick a window, Esc to cancel. The capture is copied to the clipboard and a menu appears in the center of the screen."
                    ) {
                        Text(ScreenshotsFeature.triggerSymbol)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                    }
                }
                .opacity(permissionGranted ? 1 : 0.5)
            }
        }
        .onAppear {
            bootstrapper.screenRecordingPermissionManager.refreshStatus()
        }
    }
}

/// Same look as the Accessibility `PermissionRequiredBanner`, for Screen Recording.
private struct ScreenRecordingPermissionBanner: View {
    @ObservedObject var bootstrapper: AppBootstrapper

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Recording access required")
                    .font(.system(size: 12, weight: .semibold))
                Text("Grant access to enable this feature. Choose Quit & Reopen when macOS offers it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button {
                bootstrapper.requestScreenRecordingAccess()
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
