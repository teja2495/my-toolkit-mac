import AppKit
import SwiftUI

struct ScreenCaptureSettingsView: View {
    @ObservedObject var bootstrapper: AppBootstrapper

    @State private var systemShortcutConflict = ScreenCaptureFeature.systemScreenshotShortcutEnabled
    @State private var cacheUsage = CaptureFiles.cacheUsage()

    private var feature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "screen-capture" })
    }

    private var permissionGranted: Bool {
        bootstrapper.screenRecordingPermissionManager.isGranted
    }

    var body: some View {
        SettingsPage(
            title: "Screen Capture",
            subtitle: "Take screenshots of an area, or record an area, a full screen, or a single app to video.",
            systemImage: "camera.viewfinder",
            isActive: (feature?.isEnabled ?? false) && permissionGranted
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
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsRow(
                            "Screenshot",
                            description: "Select an area or press Space for a window. Copied to the clipboard."
                        ) {
                            ShortcutBadge(symbol: ScreenCaptureFeature.screenshotSymbol)
                        }

                        SettingsCardDivider()

                        SettingsRow(
                            "Screen recording",
                            description: "Record an area, a screen, or an app. Press again to stop."
                        ) {
                            ShortcutBadge(symbol: ScreenCaptureFeature.recordingSymbol)
                        }

                        SettingsCardDivider()

                        SettingsRow(
                            "Minimize apps before recording",
                            description: "Hide open apps while recording; they come back when it stops."
                        ) {
                            Toggle("", isOn: $bootstrapper.screenCaptureHidesAppsBeforeRecording)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                        }
                    }
                }
                .opacity(permissionGranted ? 1 : 0.5)

                SettingsCard {
                    SettingsRow(
                        "Cached captures",
                        description: "Deleted after 24 hours. Desktop copies aren't affected. \(cacheUsageText)"
                    ) {
                        Button("Clear") {
                            CaptureFiles.removeAllCaptures()
                            cacheUsage = CaptureFiles.cacheUsage()
                        }
                        .controlSize(.small)
                        .disabled(cacheUsage.count == 0)
                    }
                }

                if systemShortcutConflict {
                    SystemShortcutConflictBanner {
                        systemShortcutConflict = ScreenCaptureFeature.systemScreenshotShortcutEnabled
                    }
                }
            }
        }
        .onAppear {
            bootstrapper.screenRecordingPermissionManager.refreshStatus()
            systemShortcutConflict = ScreenCaptureFeature.systemScreenshotShortcutEnabled
            cacheUsage = CaptureFiles.cacheUsage()
        }
    }

    private var cacheUsageText: String {
        guard cacheUsage.count > 0 else { return "Nothing cached." }
        let size = ByteCountFormatter.string(fromByteCount: cacheUsage.bytes, countStyle: .file)
        return "\(cacheUsage.count) file\(cacheUsage.count == 1 ? "" : "s"), \(size)."
    }
}

private struct ShortcutBadge: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .keycapStyle()
    }
}

/// macOS's own ⌘⇧3 wins over app shortcuts, so the recording shortcut needs it turned off.
private struct SystemShortcutConflictBanner: View {
    let onRecheck: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "keyboard.badge.exclamationmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("macOS is using ⌘⇧3")
                    .font(.system(size: 12, weight: .semibold))
                Text("Turn off “Save picture of screen as a file” in System Settings › Keyboard › Keyboard Shortcuts › Screenshots so ⌘⇧3 starts a recording.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)

                Button("Re-check", action: onRecheck)
                    .controlSize(.small)
                    .buttonStyle(.link)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.settingsSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.settingsSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }
}
