import AppKit
import ApplicationServices
import Combine
import SwiftUI

@MainActor
final class DockWindowPopupController {
    private let panel: NSPanel
    private let windowProvider = AppWindowTitleProvider()
    private var hostingController: NSHostingController<AnyView>
    private var latestFocusRequestID: UInt64 = 0
    private var initialWindowCount: Int = 0

    init() {
        hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        panel = NSPanel(
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
        setView(for: app, windows: windows, vscodeFolderShortcuts: vscodeFolderShortcuts, hideWindowsList: hideWindowsList)
        let size = preferredSize(for: app, windows: windows, vscodeFolderShortcuts: vscodeFolderShortcuts, hideWindowsList: hideWindowsList)
        panel.setFrame(frame(for: size, anchoredTo: app.dockItemFrame), display: true)
        panel.orderFrontRegardless()
    }

    func updateContent(
        for app: DockHoveredApplication,
        windows: [WindowInfo],
        vscodeFolderShortcuts: [VSCodeFolderShortcut]
    ) {
        let hideWindowsList = initialWindowCount == 1
        setView(for: app, windows: windows, vscodeFolderShortcuts: vscodeFolderShortcuts, hideWindowsList: hideWindowsList)
        let size = preferredSize(for: app, windows: windows, vscodeFolderShortcuts: vscodeFolderShortcuts, hideWindowsList: hideWindowsList)
        panel.setFrame(frame(for: size, anchoredTo: app.dockItemFrame), display: true)
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func setView(
        for app: DockHoveredApplication,
        windows: [WindowInfo],
        vscodeFolderShortcuts: [VSCodeFolderShortcut],
        hideWindowsList: Bool
    ) {
        let icon = NSRunningApplication(processIdentifier: app.processIdentifier)?.icon
        let isAppFocused = NSRunningApplication(processIdentifier: app.processIdentifier)?.isActive ?? false
        let foregroundProcessIdentifier = app.processIdentifier
        let isVSCodeApp = isVSCodeBundle(app.bundleIdentifier)
        let showNewWindowButton = isChromeBundle(app.bundleIdentifier) || isXcodeBundle(app.bundleIdentifier)
        hostingController.rootView = AnyView(
            DockWindowPopupView(
                appIcon: icon,
                appName: app.displayName,
                windows: Array(windows.prefix(8)),
                vscodeFolderShortcuts: vscodeFolderShortcuts,
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
                        processIdentifier: app.processIdentifier
                    )
                }
            )
        )
        makePanelHierarchyTransparent()
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
        vscodeFolderShortcuts: [VSCodeFolderShortcut],
        hideWindowsList: Bool
    ) -> CGSize {
        let rowCount: Int
        if isVSCodeBundle(app.bundleIdentifier) {
            rowCount = vscodeFolderShortcuts.count
        } else {
            let newWindowRow = (isChromeBundle(app.bundleIdentifier) || isXcodeBundle(app.bundleIdentifier)) ? 1 : 0
            rowCount = hideWindowsList ? newWindowRow : Array(windows.prefix(8)).count + newWindowRow
        }
        let width = 340.0

        // 8px padding top + bottom, 44px app header, and rows.
        var height = 16.0 + 44.0
        if rowCount > 0 {
            height += 6.0 + CGFloat(rowCount) * 44.0 + CGFloat(rowCount - 1) * 6.0
        }
        return CGSize(width: width, height: height)
    }

    private func openVSCodeFolder(_ shortcut: VSCodeFolderShortcut, processIdentifier: pid_t) {
        let path = shortcut.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }

        hide()
        let folderURL = URL(fileURLWithPath: path, isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        if let app = NSRunningApplication(processIdentifier: processIdentifier),
           let bundleURL = app.bundleURL {
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
        _ = app.terminate()
        Task { @MainActor in
            let didTerminate = await waitForApplicationTransition(timeout: 10) {
                app.isTerminated
            }
            guard didTerminate else {
                return
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in }
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
    let vscodeFolderShortcuts: [VSCodeFolderShortcut]
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

    var body: some View {
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
                ForEach(vscodeFolderShortcuts) { shortcut in
                    WindowRow(
                        icon: appIcon,
                        title: shortcutDisplayName(for: shortcut.path),
                        subtitle: shortcut.path,
                        onOpen: { onOpenVSCodeFolder(shortcut) },
                        onClose: nil
                    )
                }
            } else {
                if !hideWindowsList {
                    ForEach(windows) { window in
                        WindowRow(
                            icon: appIcon,
                            title: window.title,
                            subtitle: nil,
                            onOpen: { onOpen(window) },
                            onClose: { onClose(window) }
                        )
                    }
                }

                if showNewWindowButton {
                    WindowRow(
                        icon: appIcon,
                        title: "New Window",
                        subtitle: nil,
                        onOpen: onNewWindow,
                        onClose: nil
                    )
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

    var body: some View {
        HStack(spacing: 10) {
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
    }
}
