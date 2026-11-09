import AppKit
import Foundation

@MainActor
final class CornerNotesFeature: AppFeature {
    let id = "corner-notes"

    private let panelController = CornerNotesPanelController()
    private var pollTimer: Timer?
    private var wasInHotCorner = false

    /// When set, the hot-corner gesture launches/activates this app instead of showing the notes panel.
    var openAppURL: URL? {
        didSet {
            if openAppURL != nil { panelController.hide() }
        }
    }

    func start() {
        guard pollTimer == nil else { return }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.updateCursorState()
            }
        }

        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        wasInHotCorner = false
        panelController.hide()
    }

    private func updateCursorState() {
        let mouseLocation = NSEvent.mouseLocation
        let hotCornerFrame = bottomRightHotCornerFrame(containing: mouseLocation)
        let isInHotCorner = hotCornerFrame?.contains(mouseLocation) == true

        if isInHotCorner, !wasInHotCorner {
            if let openAppURL {
                openApp(at: openAppURL)
            } else if panelController.isVisible {
                panelController.hide()
            } else {
                panelController.show(near: hotCornerFrame)
            }
        }

        wasInHotCorner = isInHotCorner
    }

    private func openApp(at url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    private func bottomRightHotCornerFrame(containing point: CGPoint) -> CGRect? {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let screen else { return nil }

        let size: CGFloat = 18
        return CGRect(
            x: screen.frame.maxX - size,
            y: screen.frame.minY,
            width: size,
            height: size
        )
    }
}

