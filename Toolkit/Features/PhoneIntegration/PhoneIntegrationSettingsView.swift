import SwiftUI

struct PhoneIntegrationSettingsView: View {
    @ObservedObject var bootstrapper: AppBootstrapper
    @ObservedObject private var controller: PhoneBridgeController
    private let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    private var feature: FeatureDescriptor? {
        bootstrapper.availableFeatures.first(where: { $0.id == "phone-integration" })
    }

    init(bootstrapper: AppBootstrapper) {
        self.bootstrapper = bootstrapper
        _controller = ObservedObject(wrappedValue: bootstrapper.phoneIntegrationController())
    }

    var body: some View {
        SettingsPage(
            eyebrow: "Phone",
            title: "Phone",
            subtitle: "Pair your Android phone with this Mac over the local network before file browsing is enabled.",
            header: {
                if let feature {
                    FeatureEnableToggle(
                        isOn: feature.isEnabled,
                        disabled: false,
                        onToggle: { bootstrapper.toggleFeature(id: feature.id) }
                    )
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 18) {
                connectionCard
                pairingCard
                trustedDevicesCard
                fileBrowserCard
            }
        }
    }

    private var connectionCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local Bridge")
                            .font(.system(size: 13, weight: .medium))
                        Text(controller.connectionState.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Refresh") {
                        controller.stop()
                        controller.start()
                    }
                    .controlSize(.small)
                }

                if controller.discoveredDevices.isEmpty {
                    Text("No Android phones found on the local network.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(controller.discoveredDevices) { device in
                            HStack(spacing: 12) {
                                Image(systemName: "phone")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(device.name)
                                    .font(.system(size: 13))
                                Spacer()
                                Button("Pair") {
                                    controller.pair(with: device)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pairingCard: some View {
        if let pending = controller.pendingPairing {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Confirm Pairing")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Approve only if this code also appears on \(pending.deviceName).")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(pending.verificationCode.chunked(into: 3).joined(separator: " "))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()

                    HStack(spacing: 10) {
                        Button("Approve") {
                            controller.approvePendingPairing()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Reject") {
                            controller.rejectPendingPairing()
                        }
                    }
                }
            }
        }
    }

    private var trustedDevicesCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Trusted Devices")
                    .font(.system(size: 13, weight: .semibold))
                if controller.trustedDevices.isEmpty {
                    Text("No Android phones are paired yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.trustedDevices) { device in
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.shield")
                                .foregroundStyle(.green)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.system(size: 13))
                                Text("Last seen \(device.lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                controller.removeTrustedDevice(id: device.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("Remove paired device")
                        }
                    }
                }
            }
        }
    }

    private var fileBrowserCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Category", selection: $controller.selectedCategory) {
                    ForEach(PhoneFileCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 10) {
                    TextField("Search", text: $controller.searchText)
                        .textFieldStyle(.roundedBorder)

                    Menu(controller.sortLabel) {
                        Button("Modified") { controller.sortLabel = "Modified" }
                        Button("Name") { controller.sortLabel = "Name" }
                        Button("Size") { controller.sortLabel = "Size" }
                    }
                    .frame(width: 110)

                    Button("Refresh") {
                        controller.refreshFiles()
                    }
                    .controlSize(.small)
                }

                if controller.isLoadingFiles {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading files…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else if filteredFiles.isEmpty {
                    VStack(alignment: .center, spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text(controller.fileBrowserMessage.isEmpty ? "No files found." : controller.fileBrowserMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(filteredFiles) { file in
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: iconName(for: file))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(file.filename)
                                            .font(.system(size: 13, weight: .medium))
                                            .lineLimit(1)
                                        Text(fileMetadataText(for: file))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            }
        }
    }

    private var filteredFiles: [PhoneFileItem] {
        let search = controller.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = controller.fileItems.filter { file in
            guard !search.isEmpty else { return true }
            return file.filename.localizedCaseInsensitiveContains(search) ||
                file.mimeType.localizedCaseInsensitiveContains(search)
        }
        switch controller.sortLabel {
        case "Name":
            return filtered.sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
        case "Size":
            return filtered.sorted { $0.size > $1.size }
        default:
            return filtered.sorted { $0.modifiedDate > $1.modifiedDate }
        }
    }

    private func fileMetadataText(for file: PhoneFileItem) -> String {
        "\(byteCountFormatter.string(fromByteCount: file.size)) • \(file.modifiedDate.formatted(date: .abbreviated, time: .shortened))"
    }

    private func iconName(for file: PhoneFileItem) -> String {
        if file.mimeType.hasPrefix("image/") {
            return "photo"
        }
        if file.mimeType.hasPrefix("video/") {
            return "film"
        }
        if file.mimeType.hasPrefix("audio/") {
            return "music.note"
        }
        if file.mimeType == "application/pdf" {
            return "doc.richtext"
        }
        return "doc"
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        var chunks: [String] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(String(self[index..<next]))
            index = next
        }
        return chunks
    }
}
