import AppKit
import ApplicationServices
import Combine
import SwiftUI

private final class DockHoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class FirstMouseHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        view = FirstMouseHostingView(rootView: rootView)
    }
}

private struct VSCodeSearchFolder: Identifiable, Equatable {
    let id: String
    let path: String
    let name: String
    let subtitle: String?
}

@MainActor
private final class VSCodeFolderSearchModel: ObservableObject {
    @Published var query: String = "" {
        didSet { refreshResults() }
    }
    @Published private(set) var results: [VSCodeSearchFolder] = []

    var onResultsChanged: (() -> Void)?

    private var indexedFolders: [VSCodeSearchFolder] = []

    func prepare() {
        indexedFolders = Self.loadFolders()
        refreshResults()
    }

    func reset() {
        if query.isEmpty {
            results = []
            return
        }
        query = ""
    }

    private func refreshResults() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextResults: [VSCodeSearchFolder]
        if trimmed.isEmpty {
            nextResults = []
        } else {
            nextResults = Array(
                indexedFolders
                    .filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
                    .prefix(8)
            )
        }
        guard nextResults != results else { return }
        results = nextResults
        onResultsChanged?()
    }

    private static func loadFolders() -> [VSCodeSearchFolder] {
        let roots: [(path: String, subtitle: String?)] = [
            ("/Users/teja2495/Projects", nil),
            ("/Users/teja2495/Projects/more", "more")
        ]
        let fileManager = FileManager.default
        var folders: [VSCodeSearchFolder] = []

        for root in roots {
            let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
            guard let contents = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for url in contents {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { continue }
                if root.subtitle == nil, url.lastPathComponent == "more" {
                    continue
                }
                folders.append(
                    VSCodeSearchFolder(
                        id: url.path,
                        path: url.standardizedFileURL.path,
                        name: url.lastPathComponent,
                        subtitle: root.subtitle
                    )
                )
            }
        }

        return folders.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

@MainActor
private final class VSCodePinnedFoldersModel: ObservableObject {
    @Published var folders: [VSCodeFolderShortcut] = []
}

@MainActor
final class DockWindowPopupController {
    private let panel: DockHoverPanel
    private let windowProvider = AppWindowTitleProvider()
    private let vscodeFolderSearch = VSCodeFolderSearchModel()
    private let vscodePinnedFolders = VSCodePinnedFoldersModel()
    private var hostingController: NSHostingController<AnyView>
    private var latestFocusRequestID: UInt64 = 0
    private var initialWindowCount: Int = 0
    private var anchoredDockItemFrame: CGRect = .zero
    private var latestPreferredSizeInputs: (
        app: DockHoveredApplication,
        windows: [WindowInfo],
        hideWindowsList: Bool
    )?
    var onPinnedFoldersPersist: (([VSCodeFolderShortcut]) -> Void)?

    init() {
        hostingController = FirstMouseHostingController(rootView: AnyView(EmptyView()))
        panel = DockHoverPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentViewController = hostingController
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false

        vscodeFolderSearch.onResultsChanged = { [weak self] in
            self?.resizeForCurrentContent()
        }

        makePanelHierarchyTransparent()
    }

    var isVisible: Bool { panel.isVisible }
    var frameOnScreen: CGRect { panel.frame }

    func show(
        for app: DockHoveredApplication,
        windows: [WindowInfo],
        vscodeFolderShortcuts: [VSCodeFolderShortcut]
    ) {
        initialWindowCount = windows.count
        let hideWindowsList = initialWindowCount == 1
        anchoredDockItemFrame = app.dockItemFrame
        if isVSCodeBundle(app.bundleIdentifier) {
            vscodePinnedFolders.folders = vscodeFolderShortcuts
            vscodeFolderSearch.reset()
            vscodeFolderSearch.prepare()
        }
        setView(for: app, windows: windows, hideWindowsList: hideWindowsList)
        let size = preferredSize(for: app, windows: windows, hideWindowsList: hideWindowsList)
        panel.setFrame(frame(for: size, anchoredTo: app.dockItemFrame), display: true)
        panel.orderFrontRegardless()
    }

    func updateContent(
        for app: DockHoveredApplication,
        windows: [WindowInfo],
        vscodeFolderShortcuts: [VSCodeFolderShortcut]
    ) {
        let hideWindowsList = initialWindowCount == 1
        anchoredDockItemFrame = app.dockItemFrame
        if isVSCodeBundle(app.bundleIdentifier) {
            vscodePinnedFolders.folders = vscodeFolderShortcuts
        }
        setView(for: app, windows: windows, hideWindowsList: hideWindowsList)
        let size = preferredSize(for: app, windows: windows, hideWindowsList: hideWindowsList)
        panel.setFrame(frame(for: size, anchoredTo: app.dockItemFrame), display: true)
    }

    func hide() {
        vscodeFolderSearch.reset()
        latestPreferredSizeInputs = nil
        panel.orderOut(nil)
    }

    private func setView(
        for app: DockHoveredApplication,
        windows: [WindowInfo],
        hideWindowsList: Bool
    ) {
        latestPreferredSizeInputs = (app, windows, hideWindowsList)
        let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier)
        let icon = runningApp?.icon ?? app.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        let isAppFocused = runningApp?.isActive ?? false
        let foregroundProcessIdentifier = app.processIdentifier
        let isVSCodeApp = isVSCodeBundle(app.bundleIdentifier)
        let showNewWindowButton = isChromeBundle(app.bundleIdentifier) || isXcodeBundle(app.bundleIdentifier)
        hostingController.rootView = AnyView(
            DockWindowPopupView(
                appIcon: icon,
                appName: app.displayName,
                windows: Array(windows.prefix(8)),
                vscodePinnedFolders: vscodePinnedFolders,
                vscodeFolderSearch: vscodeFolderSearch,
                isVSCodeApp: isVSCodeApp,
                showNewWindowButton: showNewWindowButton,
                isAppFocused: isAppFocused,
                hideWindowsList: hideWindowsList,
                onHide: { [weak self] in
                    self?.closeAllWindows(processIdentifier: app.processIdentifier)
                },
                onRestart: { [weak self] in
                    self?.restartApplication(processIdentifier: app.processIdentifier)
                },
                onQuit: { [weak self] in
                    self?.quitApplication(processIdentifier: app.processIdentifier)
                },
                onForceQuit: { [weak self] in
                    self?.forceQuitApplication(processIdentifier: app.processIdentifier)
                },
                onOpen: { [weak self] windowInfo in
                    self?.focusWindow(windowInfo, foregroundProcessIdentifier: foregroundProcessIdentifier)
                },
                onClose: { [weak self] windowInfo in
                    self?.closeWindow(
                        windowInfo,
                        for: app,
                        visibleWindows: windows
                    )
                },
                onNewWindow: { [weak self] in
                    self?.openNewWindow(processIdentifier: app.processIdentifier)
                },
                onOpenVSCodeFolder: { [weak self] shortcut in
                    self?.openVSCodeFolder(
                        shortcut,
                        processIdentifier: app.processIdentifier,
                        bundleURL: app.bundleURL
                    )
                },
                onPinVSCodeFolder: { [weak self] path in
                    self?.pinVSCodeFolder(path)
                },
                onUnpinVSCodeFolder: { [weak self] shortcut in
                    self?.unpinVSCodeFolder(shortcut)
                },
                onFocusSearchField: { [weak self] in
                    self?.makePanelKeyForSearch()
                }
            )
        )
        makePanelHierarchyTransparent()
    }

    private func makePanelKeyForSearch() {
        panel.makeKeyAndOrderFront(nil)
    }

    private func pinVSCodeFolder(_ path: String) {
        let standardizedPath = standardizedFolderPath(path)
        guard !standardizedPath.isEmpty else { return }
        guard !vscodePinnedFolders.folders.contains(where: { $0.path == standardizedPath }) else { return }

        vscodePinnedFolders.folders.append(VSCodeFolderShortcut(path: standardizedPath))
        onPinnedFoldersPersist?(vscodePinnedFolders.folders)
        resizeForCurrentContent()
    }

    private func unpinVSCodeFolder(_ shortcut: VSCodeFolderShortcut) {
        let standardizedPath = standardizedFolderPath(shortcut.path)
        vscodePinnedFolders.folders.removeAll {
            $0.id == shortcut.id || $0.path == standardizedPath
        }
        onPinnedFoldersPersist?(vscodePinnedFolders.folders)
        resizeForCurrentContent()
    }

    private func standardizedFolderPath(_ path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return "" }
        let expandedPath = (trimmedPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath).standardizedFileURL.path
    }

    private func resizeForCurrentContent() {
        guard panel.isVisible, let inputs = latestPreferredSizeInputs else { return }
        let size = preferredSize(
            for: inputs.app,
            windows: inputs.windows,
            hideWindowsList: inputs.hideWindowsList
        )
        panel.setFrame(frame(for: size, anchoredTo: anchoredDockItemFrame), display: true)
    }

    private func makePanelHierarchyTransparent() {
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func closeAllWindows(processIdentifier: pid_t) {
        let axApp = AXUIElementCreateApplication(processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let axWindows = ref as? [AXUIElement] else {
            hide()
            return
        }
        for axWindow in axWindows {
            var closeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeRef) == .success,
               let closeButton = closeRef {
                AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
            }
        }
        hide()
    }

    private func focusWindow(_ windowInfo: WindowInfo, foregroundProcessIdentifier: pid_t) {
        latestFocusRequestID &+= 1
        let requestID = latestFocusRequestID

        let pid = windowInfo.ownerProcessIdentifier
        guard let ownerApp = NSRunningApplication(processIdentifier: pid) else { return }
        let foregroundApp = NSRunningApplication(processIdentifier: foregroundProcessIdentifier) ?? ownerApp

        // Dismiss popup first so it doesn't remain above the activated app.
        hide()
        forceForeground(foregroundApp, requestID: requestID)

        let axApp = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let axWindows = ref as? [AXUIElement] else {
            forceForeground(foregroundApp, requestID: requestID)
            return
        }

        var didFocusWindow = false
        for (index, axWindow) in axWindows.enumerated() {
            if let accessibilityIndex = windowInfo.accessibilityIndex, accessibilityIndex != index {
                continue
            }

            if windowInfo.accessibilityIndex == nil {
                var titleRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                      (titleRef as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == windowInfo.title else { continue }
            }

            _ = AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            _ = AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, axWindow)
            didFocusWindow = true
            break
        }

        forceForeground(foregroundApp, requestID: requestID)
        if !didFocusWindow {
            forceForeground(ownerApp, requestID: requestID)
        }
    }

    private func forceForeground(_ app: NSRunningApplication, requestID: UInt64) {
        app.unhide()
        _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard requestID == latestFocusRequestID else { return }
            guard !app.isActive else { return }
            _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

            // Last resort for apps that ignore activate() from background-accessibility flows.
            guard let bundleURL = app.bundleURL else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in }
        }
    }

    private func closeWindow(
        _ windowInfo: WindowInfo,
        for app: DockHoveredApplication,
        visibleWindows: [WindowInfo]
    ) {
        let pid = windowInfo.ownerProcessIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let axWindows = ref as? [AXUIElement] else { return }

        guard let axWindow = matchingAXWindow(in: axWindows, for: windowInfo) else { return }

        var closeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeRef) == .success,
              let closeButton = closeRef else { return }

        AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
        let remainingWindows = visibleWindows.filter { !isSameWindow($0, as: windowInfo) }
        if remainingWindows.isEmpty {
            hide()
            return
        }

        Task { @MainActor in
            // Allow the target app a moment to apply the close action, then refresh from source of truth.
            try? await Task.sleep(nanoseconds: 70_000_000)
            let refreshedWindows = windowProvider.windows(
                for: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier
            )
            if refreshedWindows.isEmpty {
                hide()
            } else {
                updateContent(
                    for: app,
                    windows: Array(refreshedWindows.prefix(8)),
                    vscodeFolderShortcuts: []
                )
            }
        }
    }

    private func matchingAXWindow(in axWindows: [AXUIElement], for windowInfo: WindowInfo) -> AXUIElement? {
        if axWindows.count == 1 {
            return axWindows[0]
        }

        if let accessibilityIndex = windowInfo.accessibilityIndex,
           axWindows.indices.contains(accessibilityIndex) {
            return axWindows[accessibilityIndex]
        }

        let targetTitle = windowInfo.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetTitle.isEmpty else { return nil }

        for axWindow in axWindows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = (titleRef as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                continue
            }
            if title == targetTitle {
                return axWindow
            }
        }

        return nil
    }

    private func isSameWindow(_ lhs: WindowInfo, as rhs: WindowInfo) -> Bool {
        if lhs.ownerProcessIdentifier != rhs.ownerProcessIdentifier {
            return false
        }

        if let leftAccessibilityIndex = lhs.accessibilityIndex,
           let rightAccessibilityIndex = rhs.accessibilityIndex {
            return leftAccessibilityIndex == rightAccessibilityIndex
        }

        return lhs.id == rhs.id && lhs.title == rhs.title
    }

    private func openNewWindow(processIdentifier: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else { return }
        hide()
        latestFocusRequestID &+= 1
        let requestID = latestFocusRequestID
        forceForeground(app, requestID: requestID)

        Task { @MainActor in
            for _ in 0..<4 {
                try? await Task.sleep(nanoseconds: 80_000_000)
                if app.isActive { break }
                _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }

            guard app.isActive else { return }
            sendNewWindowShortcut()
        }
    }

    private func sendNewWindowShortcut() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyCodeN: CGKeyCode = 45
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeN, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeN, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func preferredSize(
        for app: DockHoveredApplication,
        windows: [WindowInfo],
        hideWindowsList: Bool
    ) -> CGSize {
        let width = 340.0

        if (windows.isEmpty || hideWindowsList) && !isVSCodeBundle(app.bundleIdentifier) {
            return CGSize(width: width, height: 174)
        }

        // 8px padding top + bottom, 44px app header, and rows.
        var height = 16.0 + 44.0

        if isVSCodeBundle(app.bundleIdentifier) {
            let isSearching = !vscodeFolderSearch.query
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            let shortcutCount = isSearching ? 0 : vscodePinnedFolders.folders.count
            let resultCount = vscodeFolderSearch.results.count
            let rowCount = shortcutCount + resultCount
            if rowCount > 0 {
                height += 6.0 + CGFloat(rowCount) * 44.0 + CGFloat(rowCount - 1) * 6.0
            }
            // Search field row under shortcuts/results.
            height += 6.0 + 44.0
        } else {
            let newWindowRow = (isChromeBundle(app.bundleIdentifier) || isXcodeBundle(app.bundleIdentifier)) ? 1 : 0
            let rowCount = hideWindowsList ? newWindowRow : Array(windows.prefix(8)).count + newWindowRow
            if rowCount > 0 {
                height += 6.0 + CGFloat(rowCount) * 44.0 + CGFloat(rowCount - 1) * 6.0
            }
        }
        return CGSize(width: width, height: height)
    }

    private func openVSCodeFolder(
        _ shortcut: VSCodeFolderShortcut,
        processIdentifier: pid_t,
        bundleURL: URL?
    ) {
        let path = shortcut.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }

        hide()
        let folderURL = URL(fileURLWithPath: path, isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        if let bundleURL = NSRunningApplication(processIdentifier: processIdentifier)?.bundleURL ?? bundleURL {
            NSWorkspace.shared.open(
                [folderURL],
                withApplicationAt: bundleURL,
                configuration: configuration
            ) { _, _ in }
        } else {
            NSWorkspace.shared.open(folderURL)
        }
    }

    private func hideApplication(processIdentifier: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else { return }
        _ = app.hide()
        Task { @MainActor in
            await waitForApplicationTransition {
                app.isHidden
            }
            hide()
        }
    }

    private func quitApplication(processIdentifier: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else { return }
        _ = app.terminate()
        Task { @MainActor in
            await waitForApplicationTransition {
                app.isTerminated
            }
            hide()
        }
    }

    private func restartApplication(processIdentifier: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier),
              let bundleURL = app.bundleURL else { return }
        let bundleIdentifier = app.bundleIdentifier

        // Capture path up front; NSRunningApplication may become stale after quit.
        let launchURL = bundleURL
        _ = app.terminate()

        Task { @MainActor in
            var didTerminate = await waitForApplicationTransition(timeout: 4) {
                app.isTerminated
            }

            // Soft quit can hang on save sheets; escalate so restart always completes.
            if !didTerminate {
                _ = app.forceTerminate()
                didTerminate = await waitForApplicationTransition(timeout: 3) {
                    app.isTerminated
                }
            }

            guard didTerminate else {
                hide()
                return
            }

            // Wait until Launch Services no longer lists this app as running.
            if let bundleIdentifier {
                _ = await waitForApplicationTransition(timeout: 3) {
                    !NSWorkspace.shared.runningApplications.contains {
                        $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
                    }
                }
            }

            // Brief settle so relaunch is not rejected as a duplicate launch.
            try? await Task.sleep(nanoseconds: 250_000_000)

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false

            do {
                _ = try await NSWorkspace.shared.openApplication(at: launchURL, configuration: configuration)
            } catch {
                // Fallbacks for apps that reject openApplication after a forced quit.
                if !NSWorkspace.shared.open(launchURL) {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    process.arguments = [launchURL.path]
                    try? process.run()
                }
            }

            hide()
        }
    }

    private func forceQuitApplication(processIdentifier: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else { return }
        _ = app.forceTerminate()
        Task { @MainActor in
            await waitForApplicationTransition {
                app.isTerminated
            }
            hide()
        }
    }

    private func waitForApplicationTransition(
        timeout: Int = 1,
        condition: @escaping () -> Bool
    ) async -> Bool {
        if condition() { return true }
        for _ in 0..<(timeout * 50) {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if condition() { return true }
        }
        return false
    }

    private func frame(for size: CGSize, anchoredTo dockItemFrame: CGRect) -> CGRect {
        let anchorMidX = dockItemFrame.midX
        let anchorTop = dockItemFrame.maxY
        let visibleFrame = NSScreen.screens.first(where: { $0.frame.intersects(dockItemFrame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 720)

        // Keep a small gap so the popup feels visually attached to the hovered Dock icon.
        var origin = CGPoint(x: anchorMidX - size.width / 2, y: anchorTop + 0)
        origin.x = max(visibleFrame.minX + 8, min(origin.x, visibleFrame.maxX - size.width - 8))

        if origin.y + size.height > visibleFrame.maxY - 8 {
            origin.y = dockItemFrame.minY - size.height - 12
        }
        origin.y = max(visibleFrame.minY + 8, origin.y)

        return CGRect(origin: origin, size: size)
    }

    private func isVSCodeBundle(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.microsoft.VSCode"
            || bundleIdentifier == "com.microsoft.VSCodeInsiders"
    }

    private func isChromeBundle(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.google.Chrome"
            || bundleIdentifier == "com.google.Chrome.beta"
            || bundleIdentifier == "com.google.Chrome.canary"
    }

    private func isXcodeBundle(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.apple.dt.Xcode"
    }
}

private struct DockWindowPopupView: View {
    let appIcon: NSImage?
    let appName: String
    let windows: [WindowInfo]
    @ObservedObject var vscodePinnedFolders: VSCodePinnedFoldersModel
    @ObservedObject var vscodeFolderSearch: VSCodeFolderSearchModel
    let isVSCodeApp: Bool
    let showNewWindowButton: Bool
    let isAppFocused: Bool
    let hideWindowsList: Bool
    let onHide: () -> Void
    let onRestart: () -> Void
    let onQuit: () -> Void
    let onForceQuit: () -> Void
    let onOpen: (WindowInfo) -> Void
    let onClose: (WindowInfo) -> Void
    let onNewWindow: () -> Void
    let onOpenVSCodeFolder: (VSCodeFolderShortcut) -> Void
    let onPinVSCodeFolder: (String) -> Void
    let onUnpinVSCodeFolder: (VSCodeFolderShortcut) -> Void
    let onFocusSearchField: () -> Void

    var body: some View {
        Group {
            if (windows.isEmpty || hideWindowsList) && !isVSCodeApp {
                EmptyAppControlsView(
                    icon: appIcon,
                    name: appName,
                    onRestart: onRestart,
                    onQuit: onQuit,
                    onForceQuit: onForceQuit
                )
            } else {
                VStack(spacing: 6) {
                    AppHeaderRow(
                        icon: appIcon,
                        name: appName,
                        showsHideButton: isAppFocused,
                        onHide: onHide,
                        onRestart: onRestart,
                        onQuit: onQuit,
                        onForceQuit: onForceQuit
                    )

                    if isVSCodeApp {
                        let isSearching = !vscodeFolderSearch.query
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty

                if !isSearching {
                    ForEach(vscodePinnedFolders.folders) { shortcut in
                        WindowRow(
                            icon: appIcon,
                            title: shortcutDisplayName(for: shortcut.path),
                            subtitle: nil,
                            onOpen: { onOpenVSCodeFolder(shortcut) },
                            onClose: nil,
                            onPin: nil,
                            onUnpin: { onUnpinVSCodeFolder(shortcut) }
                        )
                    }
                }

                ForEach(vscodeFolderSearch.results) { folder in
                    let pinnedShortcut = pinnedShortcut(for: folder.path)
                    WindowRow(
                        icon: appIcon,
                        title: folder.name,
                        subtitle: folder.subtitle,
                        onOpen: {
                            onOpenVSCodeFolder(VSCodeFolderShortcut(path: folder.path))
                        },
                        onClose: nil,
                        onPin: pinnedShortcut == nil ? { onPinVSCodeFolder(folder.path) } : nil,
                        onUnpin: pinnedShortcut.map { shortcut in
                            { onUnpinVSCodeFolder(shortcut) }
                        }
                    )
                }

                VSCodeFolderSearchField(
                    text: $vscodeFolderSearch.query,
                    onFocus: onFocusSearchField
                )
                } else {
                    if !hideWindowsList {
                        ForEach(windows) { window in
                            WindowRow(
                                icon: appIcon,
                                title: window.title,
                                subtitle: nil,
                                onOpen: { onOpen(window) },
                                onClose: { onClose(window) },
                                onPin: nil,
                                onUnpin: nil
                            )
                        }
                    }

                    if showNewWindowButton {
                        WindowRow(
                            icon: appIcon,
                            title: "New Window",
                            subtitle: nil,
                            onOpen: onNewWindow,
                            onClose: nil,
                            onPin: nil,
                            onUnpin: nil
                        )
                    }
                }
            }
        }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .preferredColorScheme(.dark)
    }

    private func shortcutDisplayName(for path: String) -> String {
        let resolvedPath = (path as NSString).expandingTildeInPath
        let folderName = URL(fileURLWithPath: resolvedPath).lastPathComponent
        return folderName.isEmpty ? resolvedPath : folderName
    }

    private func pinnedShortcut(for path: String) -> VSCodeFolderShortcut? {
        let standardizedPath = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
        return vscodePinnedFolders.folders.first { $0.path == standardizedPath }
    }
}

private struct EmptyAppControlsView: View {
    let icon: NSImage?
    let name: String
    let onRestart: () -> Void
    let onQuit: () -> Void
    let onForceQuit: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 44, height: 44)
                }

                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
            }

            HStack(spacing: 10) {
                AppControlButton(title: "Quit", action: onQuit)
                AppControlButton(title: "Restart", action: onRestart)
                AppControlButton(title: "Force Quit", action: onForceQuit)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .onHover { _ in
            NSCursor.arrow.set()
        }
    }
}

private struct AppControlButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 74, minHeight: 34)
                .padding(.horizontal, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.18))
                )
        }
        .buttonStyle(.plain)
        .onHover { _ in
            NSCursor.arrow.set()
        }
    }
}

private struct VSCodeFolderSearchField: View {
    @Binding var text: String
    let onFocus: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)

            VSCodeFolderSearchTextField(text: $text, onFocus: onFocus)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct VSCodeFolderSearchTextField: NSViewRepresentable {
    @Binding var text: String
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onFocus: onFocus)
    }

    func makeNSView(context: Context) -> FocusAwareSearchField {
        let field = FocusAwareSearchField(frame: .zero)
        field.placeholderString = "Search Projects…"
        field.stringValue = text
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.textColor = .labelColor
        field.delegate = context.coordinator
        field.onFocus = { [weak field] in
            context.coordinator.onFocus()
            field?.window?.makeFirstResponder(field)
        }
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ nsView: FocusAwareSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.onFocus = onFocus
        nsView.onFocus = { [weak nsView] in
            context.coordinator.onFocus()
            nsView?.window?.makeFirstResponder(nsView)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onFocus: () -> Void
        weak var field: FocusAwareSearchField?

        init(text: Binding<String>, onFocus: @escaping () -> Void) {
            self.text = text
            self.onFocus = onFocus
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            onFocus()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let ideal = cellSize(forBounds: rect)
        var drawingRect = super.drawingRect(forBounds: rect)
        let delta = drawingRect.height - ideal.height
        if delta > 0 {
            drawingRect.origin.y += floor(delta / 2)
            drawingRect.size.height -= delta
        }
        return drawingRect
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }
}

private final class FocusAwareSearchField: NSTextField {
    var onFocus: (() -> Void)?

    override class var cellClass: AnyClass? {
        get { VerticallyCenteredTextFieldCell.self }
        set {}
    }

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

private struct AppHeaderRow: View {
    let icon: NSImage?
    let name: String
    let showsHideButton: Bool
    let onHide: () -> Void
    let onRestart: () -> Void
    let onQuit: () -> Void
    let onForceQuit: () -> Void
    private let actionButtonSize = CGSize(width: 34, height: 24)

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
            }

            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                if showsHideButton {
                    HideActionButton(action: onHide, size: actionButtonSize)
                }
                ActionButton(
                    systemImage: "arrow.clockwise",
                    tint: .white,
                    backgroundTint: Color.white.opacity(0.16),
                    size: actionButtonSize,
                    action: onRestart
                )
                QuitActionButton(
                    systemImage: "power",
                    tint: .white,
                    backgroundTint: Color.white.opacity(0.16),
                    size: actionButtonSize,
                    onQuit: onQuit,
                    onForceQuit: onForceQuit
                )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}

private struct HideActionButton: View {
    let action: () -> Void
    let size: CGSize

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size.width, height: size.height)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.16))
                )
        }
        .buttonStyle(.plain)
    }
}

private struct ActionButton: View {
    let systemImage: String
    let tint: Color
    let backgroundTint: Color
    let size: CGSize
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size.width, height: size.height)
                .background(
                    Capsule(style: .continuous)
                        .fill(backgroundTint)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct QuitActionButton: View {
    let systemImage: String
    let tint: Color
    let backgroundTint: Color
    let size: CGSize
    let onQuit: () -> Void
    let onForceQuit: () -> Void

    var body: some View {
        MouseButtonActionView(leftAction: onQuit, rightAction: onForceQuit) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size.width, height: size.height)
                .background(
                    Capsule(style: .continuous)
                        .fill(backgroundTint)
                )
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct MouseButtonActionView<Content: View>: NSViewRepresentable {
    let leftAction: () -> Void
    let rightAction: () -> Void
    let content: Content

    init(
        leftAction: @escaping () -> Void,
        rightAction: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.leftAction = leftAction
        self.rightAction = rightAction
        self.content = content()
    }

    func makeNSView(context: Context) -> MouseButtonHostingView<Content> {
        let view = MouseButtonHostingView(rootView: content)
        view.leftAction = leftAction
        view.rightAction = rightAction
        return view
    }

    func updateNSView(_ nsView: MouseButtonHostingView<Content>, context: Context) {
        nsView.rootView = content
        nsView.leftAction = leftAction
        nsView.rightAction = rightAction
    }
}

private final class MouseButtonHostingView<Content: View>: NSHostingView<Content> {
    var leftAction: (() -> Void)?
    var rightAction: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        leftAction?()
    }

    override func rightMouseDown(with event: NSEvent) {
        rightAction?()
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            rightAction?()
        } else {
            super.otherMouseDown(with: event)
        }
    }
}

private struct WindowRow: View {
    let icon: NSImage?
    let title: String
    let subtitle: String?
    let onOpen: (() -> Void)?
    let onClose: (() -> Void)?
    let onPin: (() -> Void)?
    let onUnpin: (() -> Void)?

    private var hasContextActions: Bool {
        onPin != nil || onUnpin != nil
    }

    var body: some View {
        let row = HStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if let onClose {
                Button(action: onClose) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.93, green: 0.27, blue: 0.27))
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen?()
        }
        .opacity(onOpen == nil ? 0.75 : 1.0)

        if hasContextActions {
            row.contextMenu {
                if let onPin {
                    Button("Pin") {
                        onPin()
                    }
                }
                if let onUnpin {
                    Button("Unpin") {
                        onUnpin()
                    }
                }
            }
        } else {
            row
        }
    }
}
