import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MiscellaneousSettingsView: View {
    @ObservedObject var bootstrapper: AppBootstrapper

    private var feature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "miscellaneous" })
    }

    private var quickNotesFeature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "corner-notes" })
    }

    private var systemHealthFeature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "system-health" })
    }

    private var mediaControlsFeature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "media-controls" })
    }

    private var purePasteFeature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "pure-paste" })
    }

    private var blockMusicAutoLaunchFeature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "block-music-autolaunch" })
    }

    var body: some View {
        SettingsPage(
            eyebrow: "Feature",
            title: "Miscellaneous",
            subtitle: "System-level helper behaviors that do not fit into a dedicated toolkit module."
        ) {
            featureToggle
        } content: {
            SettingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    if let quickNotesFeature {
                        VStack(alignment: .leading, spacing: 6) {
                            SettingsRow(
                                quickNotesFeature.title,
                                description: quickNotesFeature.summary
                            ) {
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { quickNotesFeature.isEnabled },
                                        set: { _ in
                                            bootstrapper.toggleFeature(id: quickNotesFeature.id)
                                        }
                                    )
                                )
                                .labelsHidden()
                                .toggleStyle(.switch)
                            }

                            if quickNotesFeature.isEnabled {
                                quickNotesOpenAppOptions
                                    .padding(.top, 10)
                                    .padding(.leading, 14)
                                    .overlay(alignment: .leading) {
                                        Rectangle()
                                            .fill(Color.primary.opacity(0.1))
                                            .frame(width: 2)
                                            .padding(.top, 10)
                                    }
                            }
                        }
                    }

                    if quickNotesFeature != nil, systemHealthFeature != nil {
                        SettingsCardDivider()
                    }

                    if let systemHealthFeature {
                        SettingsRow(
                            systemHealthFeature.title,
                            description: systemHealthFeature.summary
                        ) {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { systemHealthFeature.isEnabled },
                                    set: { _ in
                                        bootstrapper.toggleFeature(id: systemHealthFeature.id)
                                    }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }

                    if systemHealthFeature != nil, mediaControlsFeature != nil {
                        SettingsCardDivider()
                    }

                    if let mediaControlsFeature {
                        VStack(alignment: .leading, spacing: 6) {
                            let isMediaControlsEnabled = mediaControlsFeature.isEnabled

                            SettingsRow(
                                mediaControlsFeature.title,
                                description: isMediaControlsEnabled ? "" : mediaControlsFeature.summary
                            ) {
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { mediaControlsFeature.isEnabled },
                                        set: { _ in
                                            bootstrapper.toggleFeature(id: mediaControlsFeature.id)
                                        }
                                    )
                                )
                                .labelsHidden()
                                .toggleStyle(.switch)
                            }

                            if isMediaControlsEnabled {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Slider(
                                            value: $bootstrapper.mediaControlsHoverDelay,
                                            in: 0...2.0,
                                            step: 0.05
                                        )
                                        .tint(Color.accentColor)

                                        Text("\(Int((bootstrapper.mediaControlsHoverDelay * 1000).rounded())) ms")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(
                                                Capsule().fill(Color.primary.opacity(0.05))
                                            )
                                            .frame(minWidth: 74, alignment: .trailing)
                                    }

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
                                .frame(maxWidth: 360)
                                .padding(.top, -10)
                                .padding(.leading, 1)
                            }
                        }
                    }

                    if mediaControlsFeature != nil, purePasteFeature != nil {
                        SettingsCardDivider()
                    }

                    if let purePasteFeature {
                        SettingsRow(
                            purePasteFeature.title,
                            description: purePasteFeature.summary
                        ) {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { purePasteFeature.isEnabled },
                                    set: { _ in
                                        bootstrapper.toggleFeature(id: purePasteFeature.id)
                                    }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }

                    if purePasteFeature != nil, blockMusicAutoLaunchFeature != nil {
                        SettingsCardDivider()
                    }

                    if let blockMusicAutoLaunchFeature {
                        SettingsRow(
                            blockMusicAutoLaunchFeature.title,
                            description: blockMusicAutoLaunchFeature.summary
                        ) {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { blockMusicAutoLaunchFeature.isEnabled },
                                    set: { _ in
                                        bootstrapper.toggleFeature(id: blockMusicAutoLaunchFeature.id)
                                    }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }
                }
            }
        }
    }

    private var quickNotesOpenAppOptions: some View {
        SettingsRow(
            "Corner Action",
            description: "What opens when the pointer reaches the corner."
        ) {
            Menu {
                Button {
                    bootstrapper.cornerNotesOpenAppInstead = false
                } label: {
                    Label("Quick Notes & Tasks", systemImage: "checklist")
                }

                Divider()

                if let appURL = selectedQuickNotesAppURL {
                    Button {
                        bootstrapper.cornerNotesOpenAppInstead = true
                    } label: {
                        Label {
                            Text(appName(for: appURL))
                        } icon: {
                            Image(nsImage: menuIcon(for: appURL))
                        }
                    }
                }

                Button("Choose App…") {
                    chooseQuickNotesApp()
                }
            } label: {
                HStack(spacing: 7) {
                    if bootstrapper.cornerNotesOpenAppInstead, let appURL = selectedQuickNotesAppURL {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(appName(for: appURL))
                    } else {
                        Image(systemName: "checklist")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                        Text("Quick Notes & Tasks")
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .settingsSurface(Capsule(), emphasized: true)
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var selectedQuickNotesAppURL: URL? {
        let path = bootstrapper.cornerNotesAppPath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func appName(for url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private func menuIcon(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    private func chooseQuickNotesApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose App"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        bootstrapper.cornerNotesAppPath = url.path
        bootstrapper.cornerNotesOpenAppInstead = true
    }

    @ViewBuilder
    private var featureToggle: some View {
        if let feature {
            FeatureEnableToggle(
                isOn: feature.isEnabled,
                disabled: false
            ) {
                bootstrapper.toggleFeature(id: feature.id)
            }
        }
    }
}
