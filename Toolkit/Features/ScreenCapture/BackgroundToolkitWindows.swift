import AppKit

/// Keeps Toolkit's own windows (Settings) from jumping in front of the user's apps when a capture
/// flow activates Toolkit (the recording toolbar, or `screencapture` handing focus back on exit).
///
/// When another app is frontmost, `stash()` orders Toolkit's titled windows out; `restore()` puts
/// them back behind every other window, where they were. When Toolkit itself is frontmost nothing
/// is touched, so a Settings window the user is looking at stays put.
@MainActor
struct BackgroundToolkitWindows {
    private(set) var windows: [NSWindow] = []
    /// The app that was frontmost when the windows were stashed.
    private(set) var previousFrontApp: NSRunningApplication?

    var isEmpty: Bool { windows.isEmpty }

    static func stash() -> BackgroundToolkitWindows {
        let frontApp = NSWorkspace.shared.frontmostApplication
        guard let frontApp, frontApp.processIdentifier != getpid() else {
            return BackgroundToolkitWindows()
        }
        // Titled windows only: skips the overlays, toolbars and menu bar status item windows.
        let windows = NSApp.windows.filter {
            $0.isVisible && !$0.isMiniaturized && $0.styleMask.contains(.titled)
        }
        windows.forEach { $0.orderOut(nil) }
        return BackgroundToolkitWindows(windows: windows, previousFrontApp: frontApp)
    }

    /// Hands focus back to the app that was frontmost if Toolkit took it, then returns the windows
    /// behind everything else.
    func restore() {
        if NSApp.isActive, let previousFrontApp, !previousFrontApp.isTerminated {
            previousFrontApp.activate()
        }
        windows.forEach { $0.orderBack(nil) }
    }
}
