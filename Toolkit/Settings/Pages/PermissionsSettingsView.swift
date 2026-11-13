import SwiftUI

struct PermissionsSettingsView: View {
    @ObservedObject var bootstrapper: AppBootstrapper

    private var trusted: Bool {
        bootstrapper.accessibilityPermissionManager.isTrusted
    }

    var body: some View {
        SettingsPage(
            title: "Permissions",
            subtitle: "Some features need Accessibility access to read and write text in other apps, or Screen Recording access to capture the screen.",
            systemImage: "lock.shield"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                PermissionStatusCard(
                    title: "Accessibility",
                    isGranted: trusted,
                    missingDescription: "Required for Dock window popup and inline grammar fix.",
                    onGrant: { bootstrapper.requestAccessibilityAccess() }
                )

                PermissionStatusCard(
                    title: "Screen Recording",
                    isGranted: bootstrapper.screenRecordingPermissionManager.isGranted,
                    missingDescription: "Required for Screen Capture. Choose Quit & Reopen when macOS offers it.",
                    onGrant: { bootstrapper.requestScreenRecordingAccess() }
                )

                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("How it's used")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 8) {
                            BulletRow(text: "Reading the focused text field for inline grammar correction.")
                            BulletRow(text: "Listing window titles of the app under the cursor in the Dock.")
                            BulletRow(text: "Capturing screenshots (⌘⇧2) and screen recordings (⌘⇧3) for Screen Capture.")
                            BulletRow(text: "No data leaves your Mac — corrections use Apple Intelligence locally.")
                        }
                    }
                }
            }
        }
    }
}

private struct PermissionStatusCard: View {
    let title: String
    let isGranted: Bool
    let missingDescription: String
    let onGrant: () -> Void

    var body: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill((isGranted ? Color.green : Color.orange).opacity(0.14))
                    Image(systemName: isGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isGranted ? Color.green : Color.orange)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(isGranted ? "Features that need this can run." : missingDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if isGranted {
                    Label("Granted", systemImage: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.green.opacity(0.16)))
                        .overlay(Capsule().strokeBorder(Color.green.opacity(0.4), lineWidth: 1))
                } else {
                    Button(action: onGrant) {
                        Text("Grant access")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }
}

private struct BulletRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 3, height: 3)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
