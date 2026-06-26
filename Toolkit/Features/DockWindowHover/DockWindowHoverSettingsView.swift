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
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("VS Code popup folders")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("\(bootstrapper.vscodeFolderShortcuts.count)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.05)))
                        }

                        Text("For VS Code dock hover, show this list instead of open windows. Tap any row in the popup to open that folder.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        SettingsRow(
                            "Accessibility features",
                            description: "Master switch for all features that require accessibility permission."
                        ) {
                            Toggle("", isOn: $bootstrapper.accessibilityFeaturesMasterEnabled)
                                .labelsHidden()
                        }

                        if bootstrapper.vscodeFolderShortcuts.isEmpty {
                            Text("No folders added yet.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 6)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(Array(bootstrapper.vscodeFolderShortcuts.enumerated()), id: \.element.id) { index, shortcut in
                                    vscodeFolderRow(shortcut: shortcut, index: index)
                                }
                            }
                        }

                        Button {
                            addVSCodeFolder()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Add folder")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .glassEffect(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
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
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func vscodeFolderRow(shortcut: VSCodeFolderShortcut, index: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(folderDisplayName(for: shortcut.path))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(shortcut.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button {
                moveVSCodeFolder(at: index, offset: -1)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("Move up")

            Button {
                moveVSCodeFolder(at: index, offset: 1)
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .disabled(index == bootstrapper.vscodeFolderShortcuts.count - 1)
            .help("Move down")

            Button {
                removeVSCodeFolder(id: shortcut.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func addVSCodeFolder() {
        bootstrapper.accessibilityFeaturesMasterEnabled = false

        let panel = NSOpenPanel()
        panel.title = "Select a folder to show in VS Code popup"
        panel.prompt = "Add Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true

        bootstrapper.setDockWindowHoverSuspended(true)

        let addSelectedFolder: (URL?) -> Void = { url in
            guard let url else { return }
            bootstrapper.vscodeFolderShortcuts.append(
                VSCodeFolderShortcut(path: url.standardizedFileURL.path)
            )
            bootstrapper.accessibilityFeaturesMasterEnabled = true
        }

        panel.begin { response in
            bootstrapper.setDockWindowHoverSuspended(false)
            guard response == .OK else { return }
            addSelectedFolder(panel.url)
        }
    }

    private func moveVSCodeFolder(at index: Int, offset: Int) {
        let destination = index + offset
        guard bootstrapper.vscodeFolderShortcuts.indices.contains(index),
              bootstrapper.vscodeFolderShortcuts.indices.contains(destination) else { return }
        var shortcuts = bootstrapper.vscodeFolderShortcuts
        let movedShortcut = shortcuts.remove(at: index)
        shortcuts.insert(movedShortcut, at: destination)
        bootstrapper.vscodeFolderShortcuts = shortcuts
    }

    private func removeVSCodeFolder(id: UUID) {
        bootstrapper.vscodeFolderShortcuts.removeAll { $0.id == id }
    }

    private func folderDisplayName(for path: String) -> String {
        let resolvedPath = (path as NSString).expandingTildeInPath
        let folderName = URL(fileURLWithPath: resolvedPath).lastPathComponent
        return folderName.isEmpty ? resolvedPath : folderName
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
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }
}
