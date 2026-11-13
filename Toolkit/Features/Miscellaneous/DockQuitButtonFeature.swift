import AppKit
import Foundation

/// Shows a small round "×" badge on the top-right corner of a running app's Dock icon while the
/// cursor rests on it. Clicking the badge quits that app.
@MainActor
final class DockQuitButtonFeature: AppFeature {
    let id = "dock-quit-button"

    /// Apps that should never get a quit badge.
    private static let excludedBundleIDs: Set<String> = ["com.apple.finder"]

    private let hoverDetector = DockHoverDetector()
    private let badgeController = DockQuitBadgeController()

    private var pollTimer: Timer?
    private var currentApplication: DockHoveredApplication?
    /// After quitting, keep the badge hidden for that Dock item until the cursor leaves it.
    private var suppressedProcessIdentifier: pid_t?
    private var lastPolledMouseLocation: CGPoint?

    func start() {
        guard pollTimer == nil else { return }

        badgeController.onQuit = { [weak self] in
            self?.quitCurrentApplication()
        }

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateHoverState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        currentApplication = nil
        suppressedProcessIdentifier = nil
        lastPolledMouseLocation = nil
        badgeController.hide()
    }

    private func updateHoverState() {
        let mouseLocation = NSEvent.mouseLocation
        if mouseLocation == lastPolledMouseLocation {
            return
        }
        lastPolledMouseLocation = mouseLocation

        // Keep the badge up while the cursor is on it (it pokes outside the icon's frame).
        if badgeController.isVisible, badgeController.frame.contains(mouseLocation) {
            return
        }

        guard
            let hovered = hoverDetector.hoveredApplication(at: mouseLocation),
            hovered.processIdentifier > 0,
            !Self.excludedBundleIDs.contains(hovered.bundleIdentifier ?? ""),
            NSRunningApplication(processIdentifier: hovered.processIdentifier)?.isTerminated == false
        else {
            currentApplication = nil
            suppressedProcessIdentifier = nil
            badgeController.hide()
            return
        }

        if hovered.processIdentifier == suppressedProcessIdentifier {
            badgeController.hide()
            return
        }
        suppressedProcessIdentifier = nil

        currentApplication = hovered
        badgeController.show(at: hovered.dockItemFrame)
    }

    private func quitCurrentApplication() {
        guard let currentApplication else { return }
        suppressedProcessIdentifier = currentApplication.processIdentifier
        self.currentApplication = nil
        badgeController.hide()
        NSRunningApplication(processIdentifier: currentApplication.processIdentifier)?.terminate()
    }
}

@MainActor
private final class DockQuitBadgeController {
    private static let badgeSize: CGFloat = 20

    var onQuit: (() -> Void)?

    private lazy var panel: NSPanel = makePanel()
    private lazy var badgeView: DockQuitBadgeView = {
        let view = DockQuitBadgeView(frame: NSRect(x: 0, y: 0, width: Self.badgeSize, height: Self.badgeSize))
        view.onClick = { [weak self] in self?.onQuit?() }
        return view
    }()

    var isVisible: Bool { panel.isVisible }
    var frame: CGRect { panel.frame }

    func show(at dockItemFrame: CGRect) {
        let size = Self.badgeSize
        // The Dock item's AX frame is larger than the icon artwork (tile padding + the icon's own
        // transparent margin), so derive the visible icon square and sit the badge on its corner.
        let iconSide = min(dockItemFrame.width, dockItemFrame.height)
        let iconRect = CGRect(
            x: dockItemFrame.midX - iconSide / 2,
            y: dockItemFrame.midY - iconSide / 2,
            width: iconSide,
            height: iconSide
        )
        let cornerInset = iconSide * 0.2
        let origin = CGPoint(
            x: iconRect.maxX - cornerInset - size / 2,
            y: iconRect.maxY - cornerInset - size / 2
        )
        let targetFrame = CGRect(origin: origin, size: CGSize(width: size, height: size))
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true)
        }
        if !panel.isVisible {
            badgeView.isHovered = false
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.badgeSize, height: Self.badgeSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = badgeView
        return panel
    }
}

private final class DockQuitBadgeView: NSView {
    var onClick: (() -> Void)?
    var isHovered = false {
        didSet {
            if isHovered != oldValue { needsDisplay = true }
        }
    }

    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let circleRect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let circle = NSBezierPath(ovalIn: circleRect)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        (isHovered ? NSColor.systemRed : NSColor(white: 0.22, alpha: 0.95)).setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.35).setStroke()
        circle.lineWidth = 0.75
        circle.stroke()

        let crossInset = circleRect.width * 0.33
        let crossRect = circleRect.insetBy(dx: crossInset, dy: crossInset)
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: crossRect.minX, y: crossRect.minY))
        cross.line(to: CGPoint(x: crossRect.maxX, y: crossRect.maxY))
        cross.move(to: CGPoint(x: crossRect.minX, y: crossRect.maxY))
        cross.line(to: CGPoint(x: crossRect.maxX, y: crossRect.minY))
        cross.lineWidth = 1.6
        cross.lineCapStyle = .round
        NSColor.white.setStroke()
        cross.stroke()
    }
}
