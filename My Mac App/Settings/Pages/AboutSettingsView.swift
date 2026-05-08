import SwiftUI

struct AboutSettingsView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        SettingsPage(
            eyebrow: "App",
            title: "About",
            subtitle: "A small collection of opinionated macOS conveniences."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.18))
                                Image(systemName: "sparkles")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .frame(width: 44, height: 44)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("My Mac App")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("Version \(appVersion) (\(buildNumber))")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }

                        SettingsCardDivider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Made with care")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("This is a personal toolkit — built feature by feature, designed to stay out of the way until the moment you need it.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
