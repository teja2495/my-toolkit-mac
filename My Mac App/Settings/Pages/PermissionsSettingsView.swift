import SwiftUI

struct PermissionsSettingsView: View {
    @ObservedObject var bootstrapper: AppBootstrapper

    private var trusted: Bool {
        bootstrapper.accessibilityPermissionManager.isTrusted
    }

    var body: some View {
        SettingsPage(
            eyebrow: "App",
            title: "Permissions",
            subtitle: "These features need accessibility access to read and write text in other apps."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard {
                    HStack(alignment: .center, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill((trusted ? Color.green : Color.orange).opacity(0.12))
                            Image(systemName: trusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(trusted ? Color.green : Color.orange)
                        }
                        .frame(width: 32, height: 32)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Accessibility")
                                .font(.system(size: 13, weight: .semibold))
                            Text(trusted
                                 ? "Granted — features can run."
                                 : "Required for Dock window popup and inline grammar fix.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        if trusted {
                            Text("ENABLED")
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(1.4)
                                .foregroundStyle(Color.green)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(Color.green.opacity(0.12))
                                )
                        } else {
                            Button {
                                bootstrapper.requestAccessibilityAccess()
                            } label: {
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

                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("How it's used")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 8) {
                            BulletRow(text: "Reading the focused text field for inline grammar correction.")
                            BulletRow(text: "Listing window titles of the app under the cursor in the Dock.")
                            BulletRow(text: "No data leaves your Mac — corrections use Apple Intelligence locally.")
                        }
                    }
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
