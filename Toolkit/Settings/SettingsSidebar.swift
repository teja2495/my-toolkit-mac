import SwiftUI

struct SettingsSidebar: View {
    @ObservedObject var bootstrapper: AppBootstrapper
    @Binding var selection: SettingsSection?

    private let embeddedInMiscellaneousFeatureIDs: Set<String> = [
        "corner-notes",
        "system-health"
    ]

    private var sidebarFeatures: [FeatureDescriptor] {
        bootstrapper.availableFeatures.filter { !embeddedInMiscellaneousFeatureIDs.contains($0.id) }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(sidebarFeatures) { feature in
                    FeatureSidebarRow(
                        feature: feature,
                        accessibilityGranted: bootstrapper.accessibilityPermissionManager.isTrusted
                    )
                    .tag(SettingsSection.feature(feature.id))
                }
            } header: {
                SectionLabel(text: "Features")
                    .padding(.top, 4)
                    .padding(.bottom, 6)
            }

            Section {
                NavRow(title: "Permissions", systemImage: "lock.shield")
                    .tag(SettingsSection.permissions)
                NavRow(title: "About", systemImage: "info.circle")
                    .tag(SettingsSection.about)
            } header: {
                SectionLabel(text: "App")
                    .padding(.top, 12)
                    .padding(.bottom, 6)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    )
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Toolkit")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Settings")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
    }
}

private struct FeatureSidebarRow: View {
    let feature: FeatureDescriptor
    let accessibilityGranted: Bool

    private var statusState: StatusDot.State {
        if feature.requiresAccessibilityAccess && !accessibilityGranted {
            return .warning
        }
        return feature.isEnabled ? .active : .inactive
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: statusState)

            Text(feature.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .help(feature.summary)
    }
}

private struct NavRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(title)
                .font(.system(size: 13))

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
