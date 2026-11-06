import AppKit
import Foundation

@MainActor
final class DockWindowHoverFeature: AppFeature {
    let id = "dock-window-hover"
    var popupDelay: TimeInterval = 0.25
    var vscodeFolderShortcuts: [VSCodeFolderShortcut] = []
    var onVSCodeFolderShortcutsChanged: (([VSCodeFolderShortcut]) -> Void)?
    var isSuspended: Bool = false {
        didSet {
            lastPolledMouseLocation = nil
            if isSuspended {
                lastHoveredApplication = nil
                pendingHoveredApplication = nil
                pendingHoverStartDate = nil
                rightClickSuppressedApplication = nil
                rightClickSuppressedDockItemFrame = nil
                cachedWindows = []
                popupController.hide()
            }
        }
    }

    private let hoverDetector = DockHoverDetector()
    private let windowProvider = AppWindowTitleProvider()
    private let popupController = DockWindowPopupController()

    private var pollTimer: Timer?
    private var rightMouseDownMonitor: Any?
    private var lastHoveredApplication: DockHoveredApplication?
    private var pendingHoveredApplication: DockHoveredApplication?
    private var pendingHoverStartDate: Date?
    private var rightClickSuppressedApplication: DockHoveredApplication?
    private var rightClickSuppressedDockItemFrame: CGRect?
    private var lastDockItemFrame: CGRect = .zero
    private var cachedWindows: [WindowInfo] = []
    private var lastWindowRefreshDate: Date = .distantPast
    private var lastPolledMouseLocation: CGPoint?

    func start() {
        guard pollTimer == nil else { return }

        popupController.onPinnedFoldersPersist = { [weak self] folders in
            guard let self else { return }
            self.vscodeFolderShortcuts = folders
            self.onVSCodeFolderShortcutsChanged?(folders)
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateHoverState()
            }
        }

        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }

        rightMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { [weak self] _ in
            Task { @MainActor in
                self?.handleRightMouseDown(at: NSEvent.mouseLocation)
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let rightMouseDownMonitor {
            NSEvent.removeMonitor(rightMouseDownMonitor)
        }
        rightMouseDownMonitor = nil

        lastHoveredApplication = nil
        pendingHoveredApplication = nil
        pendingHoverStartDate = nil
        rightClickSuppressedApplication = nil
        rightClickSuppressedDockItemFrame = nil
        lastDockItemFrame = .zero
        cachedWindows = []
        lastPolledMouseLocation = nil
        popupController.hide()
    }

    private func updateHoverState() {
        if isSuspended {
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        if mouseLocation == lastPolledMouseLocation,
           pendingHoveredApplication == nil,
           !popupController.isVisible {
            return
        }
        lastPolledMouseLocation = mouseLocation

        // Stay open while the cursor is inside the popup itself.
        if popupController.isVisible, popupController.frameOnScreen.contains(mouseLocation) {
            return
        }

        // Freeze the popup while a screenshot selection is in progress so it can be captured.
        if popupController.isVisible, isScreenshotInProgress() {
            return
        }

        guard let hoveredApplication = hoverDetector.hoveredApplication(at: mouseLocation) else {
            lastHoveredApplication = nil
            pendingHoveredApplication = nil
            pendingHoverStartDate = nil
            if let suppressedFrame = rightClickSuppressedDockItemFrame,
               suppressedFrame.insetBy(dx: -8, dy: -8).contains(mouseLocation) {
                cachedWindows = []
                popupController.hide()
                return
            }
            rightClickSuppressedApplication = nil
            rightClickSuppressedDockItemFrame = nil
            cachedWindows = []
            popupController.hide()
            return
        }

        if rightClickSuppressedApplication == hoveredApplication {
            lastHoveredApplication = nil
            pendingHoveredApplication = nil
            pendingHoverStartDate = nil
            cachedWindows = []
            popupController.hide()
            return
        } else {
            rightClickSuppressedApplication = nil
            rightClickSuppressedDockItemFrame = nil
        }

        lastDockItemFrame = hoveredApplication.dockItemFrame
        let isSameApp = hoveredApplication == lastHoveredApplication

        if !isSameApp {
            if pendingHoveredApplication != hoveredApplication {
                pendingHoveredApplication = hoveredApplication
                pendingHoverStartDate = Date()
                cachedWindows = []
                popupController.hide()
            }

            guard hasSatisfiedPopupDelay() else { return }
        }

        let isVSCode = isVSCodeBundle(hoveredApplication.bundleIdentifier)
        if isVSCode {
            cachedWindows = []
            lastWindowRefreshDate = Date()
        } else if !isSameApp || shouldRefreshWindows() {
            cachedWindows = windowProvider.windows(
                for: hoveredApplication.processIdentifier,
                bundleIdentifier: hoveredApplication.bundleIdentifier
            )
            lastWindowRefreshDate = Date()
        }

        if isSameApp {
            // VS Code popup owns local search state/focus; avoid rebuilding it every poll tick.
            if !isVSCode {
                popupController.updateContent(
                    for: hoveredApplication,
                    windows: cachedWindows,
                    vscodeFolderShortcuts: vscodeFolderShortcuts
                )
            }
        } else {
            popupController.show(
                for: hoveredApplication,
                windows: cachedWindows,
                vscodeFolderShortcuts: vscodeFolderShortcuts
            )
            lastHoveredApplication = hoveredApplication
            pendingHoveredApplication = nil
            pendingHoverStartDate = nil
        }
    }

    private func shouldRefreshWindows() -> Bool {
        Date().timeIntervalSince(lastWindowRefreshDate) >= 0.8
    }

    private func hasSatisfiedPopupDelay() -> Bool {
        guard popupDelay > 0 else { return true }
        guard let pendingHoverStartDate else { return false }
        return Date().timeIntervalSince(pendingHoverStartDate) >= popupDelay
    }

    private func handleRightMouseDown(at mouseLocation: CGPoint) {
        // Keep the popup open for in-popup actions like pin/unpin.
        if popupController.isVisible, popupController.frameOnScreen.contains(mouseLocation) {
            return
        }

        let clickedApplication = hoverDetector.hoveredApplication(at: mouseLocation) ?? lastHoveredApplication
        guard let clickedApplication else { return }
        lastHoveredApplication = nil
        pendingHoveredApplication = nil
        pendingHoverStartDate = nil
        rightClickSuppressedApplication = clickedApplication
        rightClickSuppressedDockItemFrame = clickedApplication.dockItemFrame
        cachedWindows = []
        popupController.hide()
    }

    /// True while the system screenshot UI (Cmd+Shift+3/4/5) shows its full-screen
    /// selection overlay. The small post-capture thumbnail is ignored so the popup
    /// resumes normal dismissal as soon as the capture finishes.
    private func isScreenshotInProgress() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let screenshotOwners: Set<String> = ["screencaptureui", "screencapture", "Screenshot"]
        let minimumOverlayArea: CGFloat = NSScreen.screens
            .map { $0.frame.width * $0.frame.height }
            .min()
            .map { $0 * 0.5 } ?? 0

        return windowList.contains { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  screenshotOwners.contains(owner),
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else { return false }
            return bounds.width * bounds.height >= minimumOverlayArea
        }
    }

    private func isVSCodeBundle(_ bundleIdentifier: String?) -> Bool {
        ProjectEditorBundle.contains(bundleIdentifier)
    }
}
