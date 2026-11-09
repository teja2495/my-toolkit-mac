import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Hard-coded global shortcuts that snap the focused window of the frontmost app.
/// ⌥← left half, ⌥→ right half, ⌥↑ maximize, ⌥↓ minimize.
/// Also ⌘⎋ to put the computer to sleep, ⌥R to restart, ⌥Q to quit and ⌥⇧Q to force quit the frontmost app.
@MainActor
final class WindowShortcutsFeature: AppFeature {
    let id = "window-shortcuts"

    enum Placement: CaseIterable {
        case leftHalf
        case rightHalf
        case fill
        case minimize

        var carbonKeyCode: Int {
            switch self {
            case .leftHalf: return kVK_LeftArrow
            case .rightHalf: return kVK_RightArrow
            case .fill: return kVK_UpArrow
            case .minimize: return kVK_DownArrow
            }
        }

        var symbol: String {
            switch self {
            case .leftHalf: return "⌥ ←"
            case .rightHalf: return "⌥ →"
            case .fill: return "⌥ ↑"
            case .minimize: return "⌥ ↓"
            }
        }

        var title: String {
            switch self {
            case .leftHalf: return "Left half"
            case .rightHalf: return "Right half"
            case .fill: return "Maximize"
            case .minimize: return "Minimize"
            }
        }

        func frame(in visibleFrame: CGRect) -> CGRect {
            let halfWidth = (visibleFrame.width / 2).rounded(.down)
            switch self {
            case .leftHalf:
                return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: halfWidth, height: visibleFrame.height)
            case .rightHalf:
                return CGRect(
                    x: visibleFrame.maxX - halfWidth,
                    y: visibleFrame.minY,
                    width: halfWidth,
                    height: visibleFrame.height
                )
            case .fill, .minimize:
                return visibleFrame
            }
        }
    }

    static let sleepShortcutSymbol = "⌘ ⎋"
    static let sleepShortcutTitle = "Sleep computer"
    static let restartAppShortcutSymbol = "⌥ R"
    static let restartAppShortcutTitle = "Restart focused app"
    static let quitAppShortcutSymbol = "⌥ Q"
    static let quitAppShortcutTitle = "Quit focused app"
    static let forceQuitAppShortcutSymbol = "⌥ ⇧ Q"
    static let forceQuitAppShortcutTitle = "Force quit focused app"
    static let openEnpassShortcutSymbol = "⌥ E"
    static let openEnpassShortcutTitle = "Open Enpass"
    private static let enpassBundleIdentifier = "in.sinew.Enpass-Desktop"

    private var hotKeys: [HotKey] = []

    func start() {
        guard hotKeys.isEmpty else { return }
        hotKeys = Placement.allCases.compactMap { placement in
            HotKey(
                carbonKeyCode: placement.carbonKeyCode,
                carbonModifiers: optionKey,
                onKeyDown: { [weak self] in
                    MainActor.assumeIsolated {
                        self?.moveFocusedWindow(to: placement)
                    }
                },
                onKeyUp: {}
            )
        }
        if let sleepHotKey = HotKey(
            carbonKeyCode: kVK_Escape,
            carbonModifiers: cmdKey,
            onKeyDown: { [weak self] in
                MainActor.assumeIsolated {
                    self?.sleepComputer()
                }
            },
            onKeyUp: {}
        ) {
            hotKeys.append(sleepHotKey)
        }
        if let restartHotKey = HotKey(
            carbonKeyCode: kVK_ANSI_R,
            carbonModifiers: optionKey,
            onKeyDown: { [weak self] in
                MainActor.assumeIsolated {
                    self?.restartFrontmostApp()
                }
            },
            onKeyUp: {}
        ) {
            hotKeys.append(restartHotKey)
        }
        if let quitHotKey = HotKey(
            carbonKeyCode: kVK_ANSI_Q,
            carbonModifiers: optionKey,
            onKeyDown: { [weak self] in
                MainActor.assumeIsolated {
                    self?.quitFrontmostApp(force: false)
                }
            },
            onKeyUp: {}
        ) {
            hotKeys.append(quitHotKey)
        }
        if let forceQuitHotKey = HotKey(
            carbonKeyCode: kVK_ANSI_Q,
            carbonModifiers: optionKey | shiftKey,
            onKeyDown: { [weak self] in
                MainActor.assumeIsolated {
                    self?.quitFrontmostApp(force: true)
                }
            },
            onKeyUp: {}
        ) {
            hotKeys.append(forceQuitHotKey)
        }
        if let enpassHotKey = HotKey(
            carbonKeyCode: kVK_ANSI_E,
            carbonModifiers: optionKey,
            onKeyDown: { [weak self] in
                MainActor.assumeIsolated {
                    self?.openEnpass()
                }
            },
            onKeyUp: {}
        ) {
            hotKeys.append(enpassHotKey)
        }
    }

    func stop() {
        // HotKey unregisters itself on deinit.
        hotKeys.removeAll()
        restartTask?.cancel()
        restartTask = nil
    }

    private var restartTask: Task<Void, Never>?

    /// The frontmost app, excluding Toolkit itself.
    private var frontmostOtherApp: NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return app
    }

    private func quitFrontmostApp(force: Bool) {
        guard let app = frontmostOtherApp else { return }
        if force {
            app.forceTerminate()
        } else {
            app.terminate()
        }
    }

    /// Quits the frontmost app gracefully and relaunches it once it has exited.
    /// If the app doesn't quit (e.g. an unsaved-changes prompt is cancelled), it is left alone.
    private func restartFrontmostApp() {
        guard restartTask == nil,
              let app = frontmostOtherApp,
              let bundleURL = app.bundleURL else {
            return
        }

        guard app.terminate() else { return }

        restartTask = Task { @MainActor [weak self] in
            defer { self?.restartTask = nil }
            // Wait up to 30s for the app to exit (leaves time to answer save prompts).
            for _ in 0..<300 {
                if app.isTerminated { break }
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
            guard app.isTerminated else { return }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            _ = try? await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
        }
    }

    private func openEnpass() {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.enpassBundleIdentifier)
            ?? URL(fileURLWithPath: "/Applications/Enpass.app")
        guard FileManager.default.fileExists(atPath: appURL.path) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
    }

    private func sleepComputer() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        try? process.run()
    }

    private func moveFocusedWindow(to placement: Placement) {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              let window = focusedWindow(of: app.processIdentifier) else {
            return
        }

        if placement == .minimize {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            return
        }

        guard let currentFrame = axFrame(of: window),
              let screen = screen(containingAXFrame: currentFrame) else {
            return
        }

        let target = axRect(fromCocoa: placement.frame(in: screen.visibleFrame))
        // Size → position → size: some apps clamp size against the current position
        // (e.g. when moving to another display), so setting size twice settles it.
        setSize(target.size, of: window)
        setPosition(target.origin, of: window)
        setSize(target.size, of: window)
    }

    // MARK: - Accessibility helpers

    private func focusedWindow(of pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement)
        }
        return nil
    }

    private func axFrame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func setPosition(_ point: CGPoint, of window: AXUIElement) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    private func setSize(_ size: CGSize, of window: AXUIElement) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    // MARK: - Coordinate conversion

    /// AX uses a top-left origin anchored to the primary display; Cocoa uses bottom-left.
    private var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    private func axRect(fromCocoa rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private func screen(containingAXFrame axFrame: CGRect) -> NSScreen? {
        let cocoaFrame = CGRect(
            x: axFrame.minX,
            y: primaryScreenHeight - axFrame.maxY,
            width: axFrame.width,
            height: axFrame.height
        )
        let best = NSScreen.screens.max { lhs, rhs in
            area(lhs.frame.intersection(cocoaFrame)) < area(rhs.frame.intersection(cocoaFrame))
        }
        if let best, area(best.frame.intersection(cocoaFrame)) > 0 {
            return best
        }
        return NSScreen.main
    }

    private func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
