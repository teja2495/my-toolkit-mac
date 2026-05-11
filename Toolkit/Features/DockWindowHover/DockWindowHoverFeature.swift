import AppKit
import Foundation

@MainActor
final class DockWindowHoverFeature: AppFeature {
    let id = "dock-window-hover"
    var popupDelay: TimeInterval = 0.25
    var vscodeFolderShortcuts: [VSCodeFolderShortcut] = []
    var isSuspended: Bool = false {
        didSet {
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

    func start() {
        guard pollTimer == nil else { return }

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
        popupController.hide()
    }

    private func updateHoverState() {
        if isSuspended {
            return
        }

        let mouseLocation = NSEvent.mouseLocation

        // Stay open while the cursor is inside the popup itself.
        if popupController.isVisible, popupController.frameOnScreen.contains(mouseLocation) {
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
            popupController.updateContent(
                for: hoveredApplication,
                windows: cachedWindows,
                vscodeFolderShortcuts: vscodeFolderShortcuts
            )
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

    private func isVSCodeBundle(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.microsoft.VSCode"
            || bundleIdentifier == "com.microsoft.VSCodeInsiders"
    }
}
