import AppKit
import Foundation

@MainActor
final class DockWindowHoverFeature: AppFeature {
    let id = "dock-window-hover"

    private let hoverDetector = DockHoverDetector()
    private let windowTitleProvider = AppWindowTitleProvider()
    private let popupController = DockWindowPopupController()

    private var pollTimer: Timer?
    private var lastHoveredApplication: DockHoveredApplication?
    private var cachedWindowTitles: [String] = []
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
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil

        lastHoveredApplication = nil
        cachedWindowTitles = []
        popupController.hide()
    }

    private func updateHoverState() {
        let mouseLocation = NSEvent.mouseLocation

        // Keep the popup open while the cursor is over it so the user can
        // interact with its contents.
        if popupController.isVisible, popupController.frameOnScreen.contains(mouseLocation) {
            return
        }

        guard let hoveredApplication = hoverDetector.hoveredApplication(at: mouseLocation) else {
            lastHoveredApplication = nil
            cachedWindowTitles = []
            popupController.hide()
            return
        }

        let isSameApp = hoveredApplication == lastHoveredApplication

        if !isSameApp || shouldRefreshWindows() {
            cachedWindowTitles = windowTitleProvider.windowTitles(for: hoveredApplication.processIdentifier)
            lastWindowRefreshDate = Date()
        }

        if isSameApp {
            // Same icon still hovered: refresh contents but don't move the panel,
            // otherwise Dock magnification would jiggle the popup.
            popupController.updateContent(
                appName: hoveredApplication.displayName,
                windowTitles: cachedWindowTitles
            )
        } else {
            popupController.show(for: hoveredApplication, windowTitles: cachedWindowTitles)
            lastHoveredApplication = hoveredApplication
        }
    }

    private func shouldRefreshWindows() -> Bool {
        Date().timeIntervalSince(lastWindowRefreshDate) >= 0.8
    }
}
