import AppKit

/// Click-through layer shown while an area recording runs: dims everything outside the recorded
/// rectangle and outlines it. Toolkit's windows are excluded from the capture, so it never appears
/// in the video.
@MainActor
final class RecordingAreaIndicator {
    private var window: NSWindow?

    /// `rect` is in display points with a top-left origin, as in `RecordingTarget.area`.
    func show(displayID: CGDirectDisplayID, rect: CGRect) {
        hide()
        guard let screen = NSScreen.screens.first(where: { $0.captureDisplayID == displayID }) else { return }

        let frame = screen.frame
        // Flip to the view's bottom-left origin.
        let selection = CGRect(
            x: rect.minX,
            y: frame.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )

        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = RecordingAreaIndicatorView(frame: CGRect(origin: .zero, size: frame.size), selection: selection)
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        self.window = window
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

private final class RecordingAreaIndicatorView: NSView {
    private static let borderWidth: CGFloat = 2
    private let selection: CGRect

    init(frame: CGRect, selection: CGRect) {
        self.selection = selection
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // Dull everything around the recorded area; the area itself stays untouched (normal colors).
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: selection))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.4).setFill()
        dim.fill()

        // Border drawn just outside the area so it never overlaps recorded pixels.
        let inset = -Self.borderWidth / 2
        let border = NSBezierPath(rect: selection.insetBy(dx: inset, dy: inset))
        border.lineWidth = Self.borderWidth
        border.setLineDash([8, 4], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        border.stroke()
    }
}
