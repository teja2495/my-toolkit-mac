import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct PhoneIntegrationSettingsView: View {
    @ObservedObject var bootstrapper: AppBootstrapper
    @ObservedObject private var controller: PhoneBridgeController
    @State private var isShowingTrustedDevices = false
    @State private var actionErrorMessage: String?
    private let photoGridColumns = [
        GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 12, alignment: .top)
    ]
    private let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    init(bootstrapper: AppBootstrapper) {
        self.bootstrapper = bootstrapper
        _controller = ObservedObject(wrappedValue: bootstrapper.phoneIntegrationController())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            connectionCard
            pairingCard
            fileBrowserCard
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, 32)
        .padding(.horizontal, 36)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $isShowingTrustedDevices) {
            trustedDevicesSheet
        }
        .alert(
            "Phone File Action Failed",
            isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        actionErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionErrorMessage ?? "")
        }
    }

    private var connectionCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.green)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(connectionTitle)
                            .font(.system(size: 13, weight: .medium))
                    }

                    Spacer()

                    Button("Trusted Devices") {
                        isShowingTrustedDevices = true
                    }
                    .controlSize(.small)

                    Button("Refresh") {
                        controller.stop()
                        controller.start()
                    }
                    .controlSize(.small)
                }

                if controller.discoveredDevices.isEmpty {
                    if !isCurrentlyConnected {
                        Text("No Android phones found on the local network.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(controller.discoveredDevices) { device in
                            HStack(spacing: 12) {
                                Image(systemName: "smartphone")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(availableDeviceLabel(for: device))
                                    .font(.system(size: 13))
                                Button(controller.isTrustedDiscoveredDevice(device) ? "Connect" : "Pair") {
                                    controller.pair(with: device)
                                }
                                .controlSize(.small)
                                Spacer()
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

    private var trustedDevicesSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
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
                .padding(20)
            }
            .navigationTitle("Trusted Devices")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        isShowingTrustedDevices = false
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 280)
    }

    private var isCurrentlyConnected: Bool {
        if case .connected = controller.connectionState {
            return true
        }
        return false
    }

    private var connectionTitle: String {
        switch controller.connectionState {
        case .connected(let name):
            return "Connected to \(name)"
        default:
            return controller.connectionState.label
        }
    }

    private var fileBrowserCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Picker("", selection: $controller.selectedCategory) {
                        ForEach(PhoneFileCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    Spacer(minLength: 0)

                    Button {
                        controller.refreshFiles()
                    } label: {
                            Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh files")
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ScrollView {
                        if controller.selectedCategory == .photosVideos {
                            LazyVGrid(columns: photoGridColumns, alignment: .leading, spacing: 12) {
                                ForEach(filteredFiles) { file in
                                    photoGridItem(for: file)
                                }
                            }
                        } else {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(filteredFiles.enumerated()), id: \.element.id) { index, file in
                                    VStack(alignment: .leading, spacing: 0) {
                                        fileListItem(for: file)
                                            .padding(.vertical, 10)
                                        if index < filteredFiles.count - 1 {
                                            Divider()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var filteredFiles: [PhoneFileItem] {
        controller.fileItems.sorted { $0.modifiedDate > $1.modifiedDate }
    }

    private func availableDeviceLabel(for device: DiscoveredPhoneDevice) -> String {
        let fallbackName = device.name.replacingOccurrences(
            of: #"^Toolkit Android\s+"#,
            with: "",
            options: .regularExpression
        )
        let baseName = controller.trustedDeviceName(for: device) ?? fallbackName
        let displayID = shortDeviceIdentifier(for: device.advertisedDeviceId ?? device.id)
        guard !displayID.isEmpty else { return baseName }
        return "\(baseName) \(displayID)"
    }

    private func shortDeviceIdentifier(for identifier: String) -> String {
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdentifier.isEmpty else { return "" }
        return String(trimmedIdentifier.suffix(4))
    }

    private func fileMetadataText(for file: PhoneFileItem) -> String {
        "\(byteCountFormatter.string(fromByteCount: file.size)) • \(file.modifiedDate.formatted(date: .abbreviated, time: .shortened))"
    }

    private func fileListItem(for file: PhoneFileItem) -> some View {
        Button {
            openInPreview(file)
        } label: {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag {
            dragItemProvider(for: file)
        }
        .contextMenu {
            fileContextMenu(for: file)
        }
    }

    private func photoGridItem(for file: PhoneFileItem) -> some View {
        Button {
            openInPreview(file)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                PhoneFileThumbnailView(file: file)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                
                if file.mimeType.hasPrefix("video/") {
                    Text(file.filename)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white.opacity(0.95))
                        .padding(8)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .onDrag {
            dragItemProvider(for: file)
        }
        .contextMenu {
            fileContextMenu(for: file)
        }
    }

    private func openInPreview(_ file: PhoneFileItem) {
        withResolvedLocalFileURL(for: file) { fileURL in
            let workspace = NSWorkspace.shared
            let configuration = NSWorkspace.OpenConfiguration()
            if let previewURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
                workspace.open([fileURL], withApplicationAt: previewURL, configuration: configuration) { _, _ in }
            } else {
                workspace.open(fileURL)
            }
        }
    }

    @ViewBuilder
    private func fileContextMenu(for file: PhoneFileItem) -> some View {
        Button("Copy to Clipboard") {
            copyFileToClipboard(file)
        }

        Button("Download") {
            downloadFile(file)
        }
    }

    private func dragItemProvider(for file: PhoneFileItem) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = file.filename
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            controller.requestLocalFileURL(for: file) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let fileURL):
                        completion(fileURL.absoluteString.data(using: .utf8), nil)
                    case .failure(let error):
                        actionErrorMessage = error.localizedDescription
                        completion(nil, error)
                    }
                }
            }
            return nil
        }
        provider.registerFileRepresentation(
            forTypeIdentifier: contentType(for: file).identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            controller.requestLocalFileURL(for: file) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let fileURL):
                        completion(fileURL, false, nil)
                    case .failure(let error):
                        actionErrorMessage = error.localizedDescription
                        completion(nil, false, error)
                    }
                }
            }
            return nil
        }
        return provider
    }

    private func copyFileToClipboard(_ file: PhoneFileItem) {
        withResolvedLocalFileURL(for: file) { fileURL in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([fileURL as NSURL])
        }
    }

    private func downloadFile(_ file: PhoneFileItem) {
        withResolvedLocalFileURL(for: file) { fileURL in
            do {
                let downloadsDirectory = try downloadsDirectoryURL()
                let destinationURL = uniqueDestinationURL(
                    in: downloadsDirectory,
                    preferredName: file.filename
                )
                try FileManager.default.copyItem(at: fileURL, to: destinationURL)
            } catch {
                actionErrorMessage = error.localizedDescription
            }
        }
    }

    private func withResolvedLocalFileURL(
        for file: PhoneFileItem,
        perform action: @escaping (URL) -> Void
    ) {
        controller.requestLocalFileURL(for: file) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let fileURL):
                    action(fileURL)
                case .failure(let error):
                    actionErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func downloadsDirectoryURL() throws -> URL {
        guard let downloadsDirectory = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return downloadsDirectory
    }

    private func uniqueDestinationURL(in directory: URL, preferredName: String) -> URL {
        let candidateURL = directory.appendingPathComponent(preferredName)
        guard FileManager.default.fileExists(atPath: candidateURL.path) else {
            return candidateURL
        }

        let baseName = candidateURL.deletingPathExtension().lastPathComponent
        let fileExtension = candidateURL.pathExtension
        var copyIndex = 2

        while true {
            let suffix = " \(copyIndex)"
            let filename = fileExtension.isEmpty
                ? baseName + suffix
                : baseName + suffix + "." + fileExtension
            let deduplicatedURL = directory.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: deduplicatedURL.path) {
                return deduplicatedURL
            }
            copyIndex += 1
        }
    }

    private func contentType(for file: PhoneFileItem) -> UTType {
        if let type = UTType(mimeType: file.mimeType) {
            return type
        }

        let fileExtension = URL(fileURLWithPath: file.filename).pathExtension
        if let type = UTType(filenameExtension: fileExtension) {
            return type
        }

        return .data
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

private struct PhoneFileThumbnailView: View {
    let file: PhoneFileItem

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.08))

            if let thumbnail = thumbnailImage {
                GeometryReader { geometry in
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height
                        )
                        .position(
                            x: geometry.size.width / 2,
                            y: geometry.size.height / 2
                        )
                }
                .clipped()
            } else {
                Image(systemName: placeholderIconName)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if file.mimeType.hasPrefix("video/") {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(radius: 6)
                            .padding(8)
                    }
                }
            }
        }
    }

    private var thumbnailImage: NSImage? {
        guard let data = file.thumbnailData else { return nil }
        if let image = NSImage(data: data) {
            return image
        }
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: .zero)
    }

    private var placeholderIconName: String {
        file.mimeType.hasPrefix("video/") ? "film" : "photo"
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
