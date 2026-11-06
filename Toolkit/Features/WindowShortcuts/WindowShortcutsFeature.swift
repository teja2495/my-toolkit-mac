import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Hard-coded global shortcuts that snap the focused window of the frontmost app.
/// ⌥← left half, ⌥→ right half, ⌥↑ maximize, ⌥↓ minimize.
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
    }

    func stop() {
        // HotKey unregisters itself on deinit.
        hotKeys.removeAll()
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
