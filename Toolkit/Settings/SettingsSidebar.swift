import SwiftUI

struct SettingsSidebar: View {
    @ObservedObject var bootstrapper: AppBootstrapper
    @Binding var selection: SettingsSection?

    private let embeddedInMiscellaneousFeatureIDs: Set<String> = [
        "corner-notes",
        "system-health",
        "media-controls",
        "pure-paste",
        "block-music-autolaunch",
        "dock-quit-button"
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
                        accessibilityGranted: bootstrapper.accessibilityPermissionManager.isTrusted,
                        screenRecordingGranted: bootstrapper.screenRecordingPermissionManager.isGranted
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
                Circle()
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    )
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Toolkit")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
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
    let screenRecordingGranted: Bool

    private var statusState: StatusDot.State {
        if feature.requiresAccessibilityAccess && !accessibilityGranted {
            return .warning
        }
        if feature.requiresScreenRecordingAccess && !screenRecordingGranted {
            return .warning
        }
        return feature.isEnabled ? .active : .inactive
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: feature.systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(feature.isEnabled ? Color.primary : Color.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(feature.isEnabled ? 0.09 : 0.05))
                )

            Text(feature.title)
                .font(.system(size: 13))
                .foregroundStyle(feature.isEnabled ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            StatusDot(state: statusState)
        }
        .padding(.vertical, 1)
        .help(feature.summary)
    }
}

private struct NavRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

            Text(title)
                .font(.system(size: 13))

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
}
