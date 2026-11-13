import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct PhoneIntegrationSettingsView: View {
    @ObservedObject var bootstrapper: AppBootstrapper
    @ObservedObject private var controller: PhoneBridgeController
    @Namespace private var categoryTabNamespace
    @State private var isDeviceDrawerExpanded = true
    @State private var lastAutoCollapseConnectionState: Bool?
    @State private var isTargetedByFileDrop = false
    @State private var isDraggingPhoneFileOut = false
    @State private var hoveredFileID: String?
    @State private var actionErrorMessage: String?
    @State private var localMouseUpMonitor: Any?
    @State private var globalMouseUpMonitor: Any?
    private let photoGridColumns = [
        GridItem(.adaptive(minimum: 124, maximum: 200), spacing: 6, alignment: .top)
    ]
    private let otherGridColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 12, alignment: .top)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                deviceHeader
                    .padding(.bottom, 16)

                pairingCard

                libraryToolbar
                    .padding(.top, 14)
                    .padding(.bottom, 6)

                libraryContent
            }
            .padding(.top, 28)
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if isTargetedByFileDrop {
                dropTargetOverlay
            }
        }
        .animation(.easeOut(duration: 0.15), value: isTargetedByFileDrop)
        .onDrop(
            of: [UTType.fileURL],
            delegate: PhoneTabDropDelegate(
                isTargeted: $isTargetedByFileDrop,
                isDraggingPhoneFileOut: $isDraggingPhoneFileOut,
                handleDroppedFiles: handleDroppedFiles(providers:)
            )
        )
        .onAppear {
            installDragResetMonitorsIfNeeded()
            syncDeviceDrawerExpansion(forceInitial: true)
            controller.refreshConnectionData()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            controller.refreshConnectionData()
        }
        .onChange(of: isCurrentlyConnected) {
            syncDeviceDrawerExpansion(forceInitial: false)
        }
        .onDisappear {
            removeDragResetMonitors()
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

    // MARK: - Device header

    private var deviceHeader: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                PhoneDeviceGlyph(isConnected: isCurrentlyConnected, isError: isConnectionError)

                VStack(alignment: .leading, spacing: 3) {
                    Text(headerTitle)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(headerSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(isConnectionError ? Color.orange : Color.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button {
                        bootstrapper.phoneClipboardSyncEnabled.toggle()
                    } label: {
                        Label("Clipboard sync", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(SettingsPillButtonStyle(isActive: bootstrapper.phoneClipboardSyncEnabled))
                    .help(bootstrapper.phoneClipboardSyncEnabled
                          ? "Mac clipboard is sent to your phone. Click to turn off."
                          : "Send your Mac clipboard to your phone automatically.")

                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            isDeviceDrawerExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("Devices")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(isDeviceDrawerExpanded ? 180 : 0))
                        }
                    }
                    .buttonStyle(SettingsPillButtonStyle())
                    .help(isDeviceDrawerExpanded ? "Hide devices" : "Show nearby and paired phones")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            if isDeviceDrawerExpanded {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)

                deviceDrawer
                    .padding(18)
                    .transition(.opacity)
            }
        }
        .background {
            shape.fill(Color.settingsSurface)
            if isCurrentlyConnected {
                shape.fill(
                    LinearGradient(
                        colors: [Color.green.opacity(0.13), Color.green.opacity(0)],
                        startPoint: .leading,
                        endPoint: UnitPoint(x: 0.6, y: 0.5)
                    )
                )
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .animation(.easeInOut(duration: 0.3), value: isCurrentlyConnected)
    }

    private var deviceDrawer: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 24) {
                deviceColumn(title: "Nearby") {
                    if controller.discoveredDevices.isEmpty {
                        Text(isCurrentlyConnected
                             ? "No other phones found on this network."
                             : "No phones found. Open Toolkit on your Android phone and keep it on the same Wi‑Fi network.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(controller.discoveredDevices) { device in
                            deviceRow {
                                Image(systemName: "smartphone")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(availableDeviceLabel(for: device))
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Button(controller.isTrustedDiscoveredDevice(device) ? "Connect" : "Pair") {
                                    controller.pair(with: device)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }

                deviceColumn(title: "Paired") {
                    if controller.trustedDevices.isEmpty {
                        Text("No phones are paired yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(controller.trustedDevices) { device in
                            deviceRow {
                                Image(systemName: "checkmark.shield.fill")
                                    .foregroundStyle(.green)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(device.name)
                                        .font(.system(size: 13))
                                        .lineLimit(1)
                                    Text("Last seen \(device.lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Button {
                                    controller.removeTrustedDevice(id: device.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Remove paired phone")
                                .accessibilityLabel("Remove \(device.name)")
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    controller.refreshConnectionData()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)

                if isCurrentlyConnected {
                    Button("Disconnect", role: .destructive) {
                        controller.disconnect()
                    }
                    .controlSize(.small)
                }

                Spacer()
            }
        }
    }

    private func deviceColumn<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func deviceRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    // MARK: - Pairing

    @ViewBuilder
    private var pairingCard: some View {
        if let pending = controller.pendingPairing {
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.accentColor.opacity(0.14)))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Pair with \(pending.deviceName)?")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Approve only if your phone shows the same code.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text(pending.verificationCode.chunked(into: 3).joined(separator: " "))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .tracking(2)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Button("Reject") {
                        controller.rejectPendingPairing()
                    }
                    Button("Approve") {
                        controller.approvePendingPairing()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
            .padding(.bottom, 16)
        }
    }

    // MARK: - Header state

    private var isCurrentlyConnected: Bool {
        if case .connected = controller.connectionState {
            return true
        }
        return false
    }

    private var isConnectionError: Bool {
        if case .error = controller.connectionState {
            return true
        }
        return false
    }

    private var headerTitle: String {
        switch controller.connectionState {
        case .connected(let name):
            return name
        case .error:
            return "Connection problem"
        case .pairing:
            return "Pairing…"
        default:
            return "No phone connected"
        }
    }

    private var headerSubtitle: String {
        switch controller.connectionState {
        case .connected:
            return footerStatusMessage ?? "Connected on your local network"
        case .error(let message):
            return message
        case .pairing:
            return "Confirm the code on both devices to finish pairing."
        default:
            let count = controller.discoveredDevices.count
            if count == 0 {
                return "Looking for phones on your network"
            }
            return count == 1 ? "1 phone nearby" : "\(count) phones nearby"
        }
    }

    private var footerStatusMessage: String? {
        let message = controller.transferStatusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }
        guard message != controller.connectionState.label else { return nil }
        return message
    }

    private func syncDeviceDrawerExpansion(forceInitial: Bool) {
        let connected = isCurrentlyConnected
        if forceInitial {
            guard lastAutoCollapseConnectionState == nil else { return }
        } else if lastAutoCollapseConnectionState == connected {
            return
        }

        isDeviceDrawerExpanded = !connected
        lastAutoCollapseConnectionState = connected
    }

    // MARK: - Library

    private var libraryToolbar: some View {
        HStack(spacing: 12) {
            categoryTabs

            Spacer(minLength: 0)

            if !controller.isLoadingFiles && !filteredFiles.isEmpty {
                Text(filteredFiles.count == 1 ? "1 item" : "\(filteredFiles.count) items")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button {
                controller.refreshFiles()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .help("Refresh files")
            .accessibilityLabel("Refresh files")
        }
    }

    private var categoryTabs: some View {
        HStack(spacing: 2) {
            ForEach(PhoneFileCategory.allCases) { category in
                let isSelected = controller.selectedCategory == category
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        controller.selectedCategory = category
                    }
                } label: {
                    Text(category.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color.settingsSurfaceStrong)
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "selectedCategory", in: categoryTabNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    @ViewBuilder
    private var libraryContent: some View {
        if controller.isLoadingFiles {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading files from your phone…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 80)
        } else if filteredFiles.isEmpty {
            libraryEmptyState
        } else {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(fileGroups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(group.title)
                                .font(.system(size: 15, weight: .semibold))
                            Text("\(group.files.count)")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }

                        LazyVGrid(
                            columns: controller.selectedCategory == .photosVideos ? photoGridColumns : otherGridColumns,
                            alignment: .leading,
                            spacing: controller.selectedCategory == .photosVideos ? 6 : 12
                        ) {
                            ForEach(group.files) { file in
                                if controller.selectedCategory == .photosVideos {
                                    photoGridItem(for: file)
                                } else {
                                    otherGridItem(for: file)
                                }
                            }
                        }
                    }
                }

                if isCurrentlyConnected {
                    Label("Drop files anywhere on this page to send them to your phone's Downloads folder.", systemImage: "arrow.down.to.line")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .padding(.top, 10)
        }
    }

    private var libraryEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: isCurrentlyConnected ? "photo.on.rectangle.angled" : "iphone.gen3.slash")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color.primary.opacity(0.06)))

            VStack(spacing: 4) {
                Text(isCurrentlyConnected ? "Nothing here yet" : "Connect your phone to browse files")
                    .font(.system(size: 14, weight: .semibold))
                Text(controller.fileBrowserMessage.isEmpty ? "No files found." : controller.fileBrowserMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            if !isCurrentlyConnected && !isDeviceDrawerExpanded {
                Button("Show devices") {
                    withAnimation(.snappy(duration: 0.22)) {
                        isDeviceDrawerExpanded = true
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }

    private var dropTargetOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.75), style: StrokeStyle(lineWidth: 2, dash: [9, 7]))

            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("Send to phone")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text("Files are saved to Downloads on your Android phone.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var filteredFiles: [PhoneFileItem] {
        controller.fileItems.sorted { $0.modifiedDate > $1.modifiedDate }
    }

    private var fileGroups: [PhoneFileDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredFiles) { calendar.startOfDay(for: $0.modifiedDate) }
        return grouped.keys.sorted(by: >).map { day in
            PhoneFileDayGroup(
                id: day,
                title: dayTitle(for: day),
                files: (grouped[day] ?? []).sorted { $0.modifiedDate > $1.modifiedDate }
            )
        }
    }

    private func dayTitle(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let today = calendar.startOfDay(for: Date())
        if let days = calendar.dateComponents([.day], from: day, to: today).day, days < 7 {
            return day.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(day, equalTo: today, toGranularity: .year) {
            return day.formatted(.dateTime.month(.wide).day())
        }
        return day.formatted(.dateTime.month(.wide).day().year())
    }

    private func availableDeviceLabel(for device: DiscoveredPhoneDevice) -> String {
        let fallbackName = device.name.replacingOccurrences(
            of: #"^Toolkit Android\s+"#,
            with: "",
            options: .regularExpression
        )
        let baseName = controller.trustedDeviceName(for: device)
            ?? device.advertisedDeviceName
            ?? fallbackName
        let displayID = shortDeviceIdentifier(for: device.advertisedDeviceId ?? device.id)
        guard !displayID.isEmpty else { return baseName }
        return "\(baseName) \(displayID)"
    }

    private func shortDeviceIdentifier(for identifier: String) -> String {
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdentifier.isEmpty else { return "" }
        return String(trimmedIdentifier.suffix(4))
    }

    // MARK: - Tiles

    private func photoGridItem(for file: PhoneFileItem) -> some View {
        let isHovered = hoveredFileID == file.id
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        return Button {
            openFile(file)
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    PhoneFileThumbnailView(file: file)
                }
                .overlay {
                    if isHovered {
                        Color.black.opacity(0.14)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if file.mimeType.hasPrefix("video/") {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.black.opacity(0.5)))
                            .padding(7)
                            .accessibilityLabel("Video")
                    }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if isHovered {
                fileHoverActions(for: file)
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredFileID = hovering ? file.id : (hoveredFileID == file.id ? nil : hoveredFileID)
            }
        }
        .onDrag {
            dragItemProvider(for: file)
        }
        .contextMenu {
            fileContextMenu(for: file)
        }
        .help(file.filename)
    }

    private func otherGridItem(for file: PhoneFileItem) -> some View {
        let isHovered = hoveredFileID == file.id

        return Button {
            openFile(file)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                Color.clear
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        PhoneFileThumbnailView(file: file)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(file.filename)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Text(byteCountFormatter.string(fromByteCount: file.size))
                        Spacer(minLength: 4)
                        Text(file.modifiedDate.formatted(date: .omitted, time: .shortened))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                .padding(.horizontal, 2)
            }
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if isHovered {
                fileHoverActions(for: file)
                    .padding(13)
                    .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredFileID = hovering ? file.id : (hoveredFileID == file.id ? nil : hoveredFileID)
            }
        }
        .onDrag {
            dragItemProvider(for: file)
        }
        .contextMenu {
            fileContextMenu(for: file)
        }
    }

    private func fileHoverActions(for file: PhoneFileItem) -> some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                fileHoverActionButton(
                    systemImage: "doc.on.doc",
                    help: "Copy to Clipboard"
                ) {
                    copyFileToClipboard(file)
                }

                fileHoverActionButton(
                    systemImage: "arrow.down.to.line",
                    help: "Download"
                ) {
                    downloadFile(file)
                }
            }
        }
    }

    private func fileHoverActionButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(help)
        .accessibilityLabel(help)
    }

    private func openFile(_ file: PhoneFileItem) {
        withResolvedLocalFileURL(for: file) { fileURL in
            let workspace = NSWorkspace.shared
            if file.mimeType.hasPrefix("video/") || file.mimeType.hasPrefix("audio/") {
                workspace.open(fileURL)
                return
            }

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
        isDraggingPhoneFileOut = true
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

    private func handleDroppedFiles(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        resolveDroppedFileURLs(from: fileProviders)
        return true
    }

    private func resolveDroppedFileURLs(from providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var resolvedURLs: [URL] = []
        var firstError: Error?

        for provider in providers {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                defer { group.leave() }

                if let error {
                    lock.lock()
                    if firstError == nil {
                        firstError = error
                    }
                    lock.unlock()
                    return
                }

                guard let fileURL = fileURL(from: data) else {
                    return
                }

                lock.lock()
                resolvedURLs.append(fileURL)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            let uniqueURLs = Array(Set(resolvedURLs)).sorted { $0.path < $1.path }
            if !uniqueURLs.isEmpty {
                controller.queueFilesForRemoteShare(uniqueURLs)
            } else if let firstError {
                actionErrorMessage = firstError.localizedDescription
            }
        }
    }

    private func fileURL(from data: Data?) -> URL? {
        guard let data else { return nil }
        if let fileURL = URL(dataRepresentation: data, relativeTo: nil), fileURL.isFileURL {
            return fileURL
        }
        guard let rawValue = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let fileURL = URL(string: rawValue),
              fileURL.isFileURL else {
            return nil
        }
        return fileURL
    }

    private func installDragResetMonitorsIfNeeded() {
        guard localMouseUpMonitor == nil, globalMouseUpMonitor == nil else { return }

        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { event in
            isDraggingPhoneFileOut = false
            return event
        }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { _ in
            Task { @MainActor in
                isDraggingPhoneFileOut = false
            }
        }
    }

    private func removeDragResetMonitors() {
        if let localMouseUpMonitor {
            NSEvent.removeMonitor(localMouseUpMonitor)
            self.localMouseUpMonitor = nil
        }
        if let globalMouseUpMonitor {
            NSEvent.removeMonitor(globalMouseUpMonitor)
            self.globalMouseUpMonitor = nil
        }
    }
}

private struct PhoneFileThumbnailView: View {
    let file: PhoneFileItem

    var body: some View {
        ZStack {
            if let thumbnail = thumbnailImage, !shouldPreferPDFPlaceholder {
                GeometryReader { geometry in
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
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
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .overlay {
                        if shouldPreferPDFPlaceholder {
                            pdfPlaceholderView
                        } else {
                            Image(systemName: placeholderIconName)
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(.secondary)
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

    private var shouldPreferPDFPlaceholder: Bool {
        file.mimeType == "application/pdf"
    }

    private var pdfPlaceholderView: some View {
        VStack(spacing: 3) {
            ZStack {
                Image(systemName: "doc.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(red: 0.88, green: 0.22, blue: 0.19))
                    .frame(width: 24, height: 12)
                    .offset(y: 9)

                Text("PDF")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(y: 9)
            }
            .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)
        }
    }

    private var placeholderIconName: String {
        if file.mimeType.hasPrefix("video/") {
            return "film"
        }
        if file.mimeType.hasPrefix("image/") {
            return "photo"
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

private struct PhoneTabDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    @Binding var isDraggingPhoneFileOut: Bool
    let handleDroppedFiles: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        let fileProviders = fileProviders(from: info)
        let isValid = !fileProviders.isEmpty
        if !isValid {
            isTargeted = false
        }
        return isValid
    }

    func dropEntered(info: DropInfo) {
        isTargeted = !fileProviders(from: info).isEmpty
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { isTargeted = false }
        let fileProviders = fileProviders(from: info)
        guard !fileProviders.isEmpty else { return false }
        return handleDroppedFiles(fileProviders)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        fileProviders(from: info).isEmpty ? DropProposal(operation: .forbidden) : DropProposal(operation: .copy)
    }

    private func fileProviders(from info: DropInfo) -> [NSItemProvider] {
        guard !isDraggingPhoneFileOut else { return [] }
        return info.itemProviders(for: [UTType.fileURL])
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

private struct PhoneFileDayGroup: Identifiable {
    let id: Date
    let title: String
    let files: [PhoneFileItem]
}

/// Phone badge for the page header. When connected, a ring pulses outward to show the live link.
private struct PhoneDeviceGlyph: View {
    let isConnected: Bool
    let isError: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    private var tint: Color {
        if isConnected { return .green }
        if isError { return .orange }
        return .secondary
    }

    var body: some View {
        ZStack {
            if isConnected && !reduceMotion {
                Circle()
                    .stroke(Color.green.opacity(0.45), lineWidth: 1.5)
                    .frame(width: 46, height: 46)
                    .scaleEffect(isPulsing ? 1.3 : 1)
                    .opacity(isPulsing ? 0 : 0.9)
            }

            Circle()
                .fill(tint.opacity(isConnected ? 0.18 : 0.1))
                .frame(width: 46, height: 46)

            Image(systemName: "smartphone")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: 52, height: 52)
        .onAppear(perform: restartPulse)
        .onChange(of: isConnected) {
            restartPulse()
        }
        .accessibilityHidden(true)
    }

    private func restartPulse() {
        isPulsing = false
        guard isConnected, !reduceMotion else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
    }
}
