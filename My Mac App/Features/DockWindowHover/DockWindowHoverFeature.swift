import AppKit
import Foundation

@MainActor
final class DockWindowHoverFeature: AppFeature {
    let id = "dock-window-hover"

    private let hoverDetector = DockHoverDetector()
    private let windowProvider = AppWindowTitleProvider()
    private let popupController = DockWindowPopupController()

    private var pollTimer: Timer?
    private var lastHoveredApplication: DockHoveredApplication?
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
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil

        lastHoveredApplication = nil
        lastDockItemFrame = .zero
        cachedWindows = []
        popupController.hide()
    }

    private func updateHoverState() {
        let mouseLocation = NSEvent.mouseLocation

        // Stay open while the cursor is inside the popup itself.
        if popupController.isVisible, popupController.frameOnScreen.contains(mouseLocation) {
            return
        }

        guard let hoveredApplication = hoverDetector.hoveredApplication(at: mouseLocation) else {
            lastHoveredApplication = nil
            cachedWindows = []
            popupController.hide()
            return
        }

        lastDockItemFrame = hoveredApplication.dockItemFrame
        let isSameApp = hoveredApplication == lastHoveredApplication

        if !isSameApp || shouldRefreshWindows() {
            cachedWindows = windowProvider.windows(
                for: hoveredApplication.processIdentifier,
                bundleIdentifier: hoveredApplication.bundleIdentifier
            )
            lastWindowRefreshDate = Date()
        }

        if isSameApp {
            popupController.updateContent(for: hoveredApplication, windows: cachedWindows)
        } else {
            popupController.show(for: hoveredApplication, windows: cachedWindows)
            lastHoveredApplication = hoveredApplication
        }
    }

    private func shouldRefreshWindows() -> Bool {
        Date().timeIntervalSince(lastWindowRefreshDate) >= 0.8
    }
}
