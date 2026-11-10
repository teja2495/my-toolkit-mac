import AppKit
import Carbon.HIToolbox
import SwiftUI

struct CaptureResultAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    /// Shown in red (e.g. Delete).
    var isDestructive = false
    let handler: () -> Void
}

/// Borderless panels refuse key status by default; this one needs it so Esc reaches it.
final class CaptureKeyablePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// The centered popup shown after a screenshot or recording: thumbnail plus follow-up actions.
@MainActor
final class CaptureResultPanelController: NSObject, NSWindowDelegate {
    private static let panelWidth: CGFloat = 280
    private static let autoCloseDelay: TimeInterval = 5

    private let panel: CaptureKeyablePanel
    private var outsideClickMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var autoCloseTimer: Timer?
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?

    override init() {
        panel = CaptureKeyablePanel(
            contentRect: CGRect(x: 0, y: 0, width: Self.panelWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
    }

    /// Shows the popup centered on the screen that contains `point`.
    func show(
        thumbnail: NSImage?,
        caption: String,
        onScreenAt point: CGPoint,
        actions: [CaptureResultAction]
    ) {
        let view = CaptureResultView(
            thumbnail: thumbnail,
            caption: caption,
            actions: actions,
            onClose: { [weak self] in self?.close() },
            onHoverChanged: { [weak self] isHovered in self?.setHovered(isHovered) },
            onDragChanged: { [weak self] in self?.dragChanged() },
            onDragEnded: { [weak self] in self?.dragEnded() }
        )
        let hostingView = NSHostingView(rootView: view)
        let size = hostingView.fittingSize
        hostingView.frame.size = size
        panel.contentView = hostingView
        panel.setFrame(centeredFrame(for: size, onScreenAt: point), display: true)

        panel.orderFrontRegardless()
        panel.makeKey()
        installMonitors()
        scheduleAutoClose()
    }

    func close() {
        dragStart = nil
        cancelAutoClose()
        removeMonitors()
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panel.contentView = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: - Dragging

    /// Moves the panel by the pointer's movement in screen coordinates. Using screen coordinates
    /// (not the gesture's view-local translation) avoids jitter as the window moves under the view.
    private func dragChanged() {
        let mouse = NSEvent.mouseLocation
        cancelAutoClose()
        guard let start = dragStart else {
            dragStart = (mouse: mouse, origin: panel.frame.origin)
            return
        }
        panel.setFrameOrigin(CGPoint(
            x: start.origin.x + (mouse.x - start.mouse.x),
            y: start.origin.y + (mouse.y - start.mouse.y)
        ))
    }

    private func dragEnded() {
        dragStart = nil
        // Normally the pointer is still over the panel and hover-exit restarts the countdown later.
        if !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
            scheduleAutoClose()
        }
    }

    // MARK: - Auto close

    /// Pauses the countdown while the pointer is over the popup and restarts it when it leaves.
    private func setHovered(_ isHovered: Bool) {
        guard panel.isVisible else { return }
        if isHovered {
            cancelAutoClose()
        } else {
            scheduleAutoClose()
        }
    }

    private func scheduleAutoClose() {
        cancelAutoClose()
        let timer = Timer(timeInterval: Self.autoCloseDelay, repeats: false) { _ in
            Task { @MainActor [weak self] in
                self?.close()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoCloseTimer = timer
    }

    private func cancelAutoClose() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
    }

    // MARK: - Placement

    private func centeredFrame(for size: CGSize, onScreenAt point: CGPoint) -> CGRect {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? CGRect(origin: .zero, size: size)
        let origin = CGPoint(
            x: (bounds.midX - size.width / 2).rounded(),
            y: (bounds.midY - size.height / 2).rounded()
        )
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Event monitors

    private func installMonitors() {
        removeMonitors()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.close()
            }
        }

        // Esc while another app keeps keyboard focus (needs Accessibility, which Toolkit already has).
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Int(event.keyCode) == kVK_Escape else { return }
            MainActor.assumeIsolated {
                self?.close()
            }
        }

        // Esc when the event is delivered to Toolkit itself.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Int(event.keyCode) == kVK_Escape else { return event }
            MainActor.assumeIsolated {
                self?.close()
            }
            return nil
        }
    }

    private func removeMonitors() {
        for monitor in [outsideClickMonitor, globalKeyMonitor, localKeyMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        outsideClickMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
    }
}

private struct CaptureResultView: View {
    let thumbnail: NSImage?
    let caption: String
    let actions: [CaptureResultAction]
    let onClose: () -> Void
    let onHoverChanged: (Bool) -> Void
    let onDragChanged: () -> Void
    let onDragEnded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(caption, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                CaptureCloseButton(action: onClose)
            }
            .padding(.leading, 4)

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1))
                    )
            }

            VStack(spacing: 2) {
                ForEach(actions) { action in
                    CaptureResultButton(
                        title: action.title,
                        systemImage: action.systemImage,
                        isDestructive: action.isDestructive,
                        action: action.handler
                    )
                }
            }
        }
        .padding(10)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .onHover(perform: onHoverChanged)
        // Hold and drag anywhere on the card to move it. A small minimum distance keeps
        // plain clicks on the buttons working.
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in onDragChanged() }
                .onEnded { _ in onDragEnded() }
        )
    }
}

struct CaptureCloseButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(Color.primary.opacity(isHovered ? 0.14 : 0.07))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Close (Esc)")
    }
}

private struct CaptureResultButton: View {
    let title: String
    let systemImage: String
    var isDestructive = false
    let action: () -> Void

    @State private var isHovered = false

    private var highlight: Color { isDestructive ? .red : .accentColor }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isHovered ? Color.white : (isDestructive ? Color.red : Color.primary))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? highlight : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
