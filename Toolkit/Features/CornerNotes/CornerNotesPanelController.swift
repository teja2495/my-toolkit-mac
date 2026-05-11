import AppKit
import SwiftUI

@MainActor
final class CornerNotesPanelController: NSObject, NSWindowDelegate {
    private static let defaultPanelSize = CGSize(width: 1040, height: 680)
    private static let minimumPanelSize = CGSize(width: 860, height: 520)
    private static let pinnedKey = "cornerNotesPinned"

    private let panel: NSPanel
    private let store = CornerNotesStore()
    private var hostingController: NSHostingController<CornerNotesView>?
    private var isPinned: Bool = UserDefaults.standard.bool(forKey: pinnedKey)

    override init() {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.defaultPanelSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.title = "Quick Notes"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.minSize = Self.minimumPanelSize
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
    }

    func show(near hotCornerFrame: CGRect?) {
        if hostingController == nil {
            let view = CornerNotesView(store: store, onPinToggle: { [weak self] pinned in
                self?.isPinned = pinned
            }, onClose: { [weak self] in
                self?.close()
            })
            let controller = NSHostingController(rootView: view)
            hostingController = controller
            panel.contentViewController = controller
        }

        if !panel.isVisible {
            panel.setFrame(frame(near: hotCornerFrame), display: true)
        }

        NSApp.activate(ignoringOtherApps: true)
        focusPanel()

        DispatchQueue.main.async {
            self.focusPanel()
            self.applyOverlayScrollers(to: self.panel.contentView)
        }
    }

    var isVisible: Bool { panel.isVisible }

    func hide() {
        panel.orderOut(nil)
    }

    func close() {
        panel.close()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isPinned else { return }
        close()
    }

    private func focusPanel() {
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    private func applyOverlayScrollers(to view: NSView?) {
        guard let view = view else { return }
        if let scrollView = view as? NSScrollView {
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
        }
        for subview in view.subviews {
            applyOverlayScrollers(to: subview)
        }
    }

    private func frame(near hotCornerFrame: CGRect?) -> CGRect {
        let size = panel.frame.size == .zero ? Self.defaultPanelSize : panel.frame.size
        let visibleFrame = hotCornerFrame.flatMap { hotCorner in
            NSScreen.screens.first(where: { $0.frame.intersects(hotCorner) })?.visibleFrame
        } ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 720)

        let origin = CGPoint(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.midY - (size.height / 2)
        )
        return CGRect(origin: origin, size: size)
    }
}
