import AppKit
import ApplicationServices
import Combine
import SwiftUI

@MainActor
final class DockWindowPopupController {
    private let panel: NSPanel
    private var hostingController: NSHostingController<AnyView>
    private var latestFocusRequestID: UInt64 = 0

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
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
    }

    var isVisible: Bool { panel.isVisible }
    var frameOnScreen: CGRect { panel.frame }

    func show(for app: DockHoveredApplication, windows: [WindowInfo]) {
        setView(for: app, windows: windows)
        let size = preferredSize(for: windows)
        panel.setFrame(frame(for: size, anchoredTo: app.dockItemFrame), display: true)
        panel.orderFrontRegardless()
    }

    func updateContent(for app: DockHoveredApplication, windows: [WindowInfo]) {
        setView(for: app, windows: windows)
        let size = preferredSize(for: windows)
        panel.setFrame(frame(for: size, anchoredTo: app.dockItemFrame), display: true)
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func setView(for app: DockHoveredApplication, windows: [WindowInfo]) {
        let icon = NSRunningApplication(processIdentifier: app.processIdentifier)?.icon
        let foregroundProcessIdentifier = app.processIdentifier
        hostingController.rootView = AnyView(
            DockWindowPopupView(
                appIcon: icon,
                appName: app.displayName,
                windows: Array(windows.prefix(8)),
                onHide: { [weak self] in
                    self?.hideApplication(processIdentifier: app.processIdentifier)
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
                    self?.closeWindow(windowInfo)
                },
                onNewWindow: { [weak self] in
                    self?.openNewWindow(processIdentifier: app.processIdentifier)
                }
            )
        )
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

    private func closeWindow(_ windowInfo: WindowInfo) {
        let pid = windowInfo.ownerProcessIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let axWindows = ref as? [AXUIElement] else { return }

        for (index, axWindow) in axWindows.enumerated() {
            if let accessibilityIndex = windowInfo.accessibilityIndex, accessibilityIndex != index {
                continue
            }

            var titleRef: CFTypeRef?
            if windowInfo.accessibilityIndex == nil {
                guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                      (titleRef as? String) == windowInfo.title else { continue }
            }

            var closeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeRef) == .success,
                  let closeButton = closeRef else { continue }

            AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
            hide()
            break
        }
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

    private func preferredSize(for windows: [WindowInfo]) -> CGSize {
        let visibleWindows = Array(windows.prefix(8))
        let windowCount = visibleWindows.count + 1 // Always include "New Window"
        let width = 340.0

        // 8px padding top + bottom, 44px app header, and window rows.
        var height = 16.0 + 44.0
        height += 6.0 + CGFloat(windowCount) * 44.0 + CGFloat(windowCount - 1) * 6.0
        return CGSize(width: width, height: height)
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

    private func waitForApplicationTransition(condition: @escaping () -> Bool) async {
        if condition() { return }
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if condition() { return }
        }
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
}

private struct DockWindowPopupView: View {
    let appIcon: NSImage?
    let appName: String
    let windows: [WindowInfo]
    let onHide: () -> Void
    let onQuit: () -> Void
    let onForceQuit: () -> Void
    let onOpen: (WindowInfo) -> Void
    let onClose: (WindowInfo) -> Void
    let onNewWindow: () -> Void
    @StateObject private var modifierKeyState = ModifierKeyState()

    var body: some View {
        VStack(spacing: 6) {
            AppHeaderRow(
                icon: appIcon,
                name: appName,
                onHide: onHide,
                onQuit: onQuit,
                onForceQuit: onForceQuit,
                modifierKeyState: modifierKeyState
            )

            ForEach(windows) { window in
                WindowRow(
                    icon: appIcon,
                    title: window.title,
                    onOpen: { onOpen(window) },
                    onClose: { onClose(window) }
                )
            }

            WindowRow(
                icon: appIcon,
                title: "New Window",
                onOpen: onNewWindow,
                onClose: nil
            )
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .preferredColorScheme(.dark)
    }
}

private struct AppHeaderRow: View {
    let icon: NSImage?
    let name: String
    let onHide: () -> Void
    let onQuit: () -> Void
    let onForceQuit: () -> Void
    @ObservedObject var modifierKeyState: ModifierKeyState

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

            HideActionButton(action: onHide)
            PowerActionButton(
                isCommandPressed: modifierKeyState.isCommandPressed,
                onQuit: onQuit,
                onForceQuit: onForceQuit
            )
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}

private struct HideActionButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
    }
}

private struct PowerActionButton: View {
    let isCommandPressed: Bool
    let onQuit: () -> Void
    let onForceQuit: () -> Void

    var body: some View {
        Button(action: {
            if isCommandPressed {
                onForceQuit()
            } else {
                onQuit()
            }
        }) {
            Image(systemName: "power")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isCommandPressed ? Color.red : Color.white)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
    }
}

@MainActor
private final class ModifierKeyState: ObservableObject {
    @Published private(set) var isCommandPressed: Bool = NSEvent.modifierFlags.contains(.command)
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(from: event.modifierFlags)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.update(from: event.modifierFlags)
            }
        }
    }

    deinit {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
    }

    private func update(from flags: NSEvent.ModifierFlags) {
        let pressed = flags.contains(.command)
        if isCommandPressed != pressed {
            isCommandPressed = pressed
        }
    }
}

private struct WindowRow: View {
    let icon: NSImage?
    let title: String
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
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
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
    }
}
