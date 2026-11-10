import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// What to record. Rects are in the display's own point space with a top-left origin,
/// which is what ScreenCaptureKit's `sourceRect` expects.
enum RecordingTarget {
    case area(displayID: CGDirectDisplayID, rect: CGRect)
    case display(displayID: CGDirectDisplayID)
    case application(pid: pid_t, preferredDisplayID: CGDirectDisplayID)
}

struct RecordableApp: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let icon: NSImage

    static func == (lhs: RecordableApp, rhs: RecordableApp) -> Bool { lhs.id == rhs.id }

    /// Regular (Dock) apps that are running, excluding Toolkit itself.
    static func running() -> [RecordableApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap { app -> RecordableApp? in
                guard let name = app.localizedName else { return nil }
                let icon = (app.icon?.copy() as? NSImage) ?? NSImage()
                icon.size = CGSize(width: 16, height: 16)
                return RecordableApp(id: app.processIdentifier, name: name, icon: icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// What was hidden when a recording started: other apps, plus Toolkit's own titled windows
/// (e.g. Settings), which can't be hidden with the app because the toolbar belongs to Toolkit too.
@MainActor
struct MinimizedApps {
    private(set) var apps: [NSRunningApplication] = []
    private(set) var toolkitWindows: [NSWindow] = []

    var isEmpty: Bool { apps.isEmpty && toolkitWindows.isEmpty }

    /// Hides every visible app (Finder windows included) and Toolkit's titled windows.
    static func hideAll() -> MinimizedApps {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != getpid()
        }
        // Titled windows only: skips the overlays, toolbars and menu bar status item windows.
        let windows = NSApp.windows.filter {
            $0.isVisible && !$0.isMiniaturized && $0.styleMask.contains(.titled)
        }
        apps.forEach { $0.hide() }
        windows.forEach { $0.orderOut(nil) }
        return MinimizedApps(apps: apps, toolkitWindows: windows)
    }

    /// Brings back only what `hideAll()` hid.
    func restore() {
        apps.filter { !$0.isTerminated }.forEach { $0.unhide() }
        toolkitWindows.forEach { $0.orderFront(nil) }
    }
}

struct RecordableDisplay: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String

    static func connected() -> [RecordableDisplay] {
        NSScreen.screens.compactMap { screen in
            screen.captureDisplayID.map { RecordableDisplay(id: $0, name: screen.localizedName) }
        }
    }
}

@MainActor
final class RecordingToolbarModel: ObservableObject {
    enum Mode: Equatable {
        case area
        case fullScreen
        case app
    }

    @Published var mode: Mode = .area
    @Published var hasSelection = false
    @Published var apps: [RecordableApp] = []
    @Published var selectedApp: RecordableApp?
    @Published var displays: [RecordableDisplay] = []
    @Published var selectedDisplayID: CGDirectDisplayID?

    /// Record system audio along with the video. Off every time the toolbar opens.
    @Published var recordAudio = false

    var canStart: Bool {
        switch mode {
        case .area: return hasSelection
        case .fullScreen: return true
        case .app: return selectedApp != nil
        }
    }
}

/// Dims every screen for area selection and shows a floating toolbar for picking what to record.
@MainActor
final class RecordingToolbarController: NSObject {
    private static let overlayLevel = NSWindow.Level.statusBar
    // Above the overlays but below pop-up menus, so the App dropdown still shows on top.
    private static let toolbarLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    private let model = RecordingToolbarModel()
    private var overlays: [RecordingOverlayWindow] = []
    private var toolbarPanel: CaptureKeyablePanel?
    private var fullScreenTarget: NSScreen? {
        didSet { model.selectedDisplayID = fullScreenTarget?.captureDisplayID }
    }
    /// Called with the target, the apps hidden for the recording (the caller restores them once the
    /// recording ends), and whether to record system audio.
    private var onStart: ((RecordingTarget, MinimizedApps, Bool) -> Void)?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var previousFrontApp: NSRunningApplication?
    /// The last area selected (display + rect in that overlay's view coordinates), restored the
    /// next time the toolbar opens. Kept for the app's lifetime only.
    private var lastSelection: (displayID: CGDirectDisplayID, rect: CGRect)?

    var isVisible: Bool { toolbarPanel != nil }
    /// The screen the toolbar was last shown on, so the stop toolbar can appear in the same place.
    private(set) var lastScreen: NSScreen?

    /// Whether starting an area or full-screen recording hides the open apps first.
    private var hidesApps = true

    func show(hidesApps: Bool, onStart: @escaping (RecordingTarget, MinimizedApps, Bool) -> Void) {
        close()
        self.onStart = onStart
        self.hidesApps = hidesApps

        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        model.displays = RecordableDisplay.connected()
        fullScreenTarget = mouseScreen

        model.mode = .area
        model.hasSelection = false
        model.apps = RecordableApp.running()
        model.selectedApp = nil
        model.recordAudio = false

        overlays = NSScreen.screens.map { screen in
            let overlay = RecordingOverlayWindow(screen: screen, level: Self.overlayLevel)
            overlay.selectionView.onSelectionChanged = { [weak self, weak overlay] hasSelection in
                guard let self, let overlay else { return }
                self.selectionChanged(on: overlay, hasSelection: hasSelection)
            }
            overlay.selectionView.onClick = { [weak self, weak overlay] in
                guard let self, let overlay, self.model.mode == .fullScreen else { return }
                self.fullScreenTarget = overlay.targetScreen
                self.applyMode()
            }
            overlay.orderFrontRegardless()
            return overlay
        }

        // While another app is frontmost, the first click on the overlay only brings it into focus,
        // so the first drag never selects anything. Activate Toolkit up front so the first drag
        // works, and hand focus back to the previous app when the toolbar closes.
        let frontApp = NSWorkspace.shared.frontmostApplication
        if frontApp?.processIdentifier != getpid() {
            previousFrontApp = frontApp
        }
        NSApp.activate()

        restoreLastSelection(fallbackScreen: mouseScreen)
        showToolbar(on: mouseScreen)
        applyMode()
        installKeyMonitors()

        model.$mode
            .dropFirst()
            .sink { [weak self] _ in
                // @Published fires before the value is stored; apply on the next turn.
                DispatchQueue.main.async { self?.applyMode() }
            }
            .store(in: &cancellables)
    }

    func close() {
        cancellables.removeAll()
        removeKeyMonitors()
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        toolbarPanel?.orderOut(nil)
        toolbarPanel = nil
        onStart = nil
        if let previousFrontApp {
            self.previousFrontApp = nil
            previousFrontApp.activate()
        }
    }

    // MARK: - Toolbar

    private func showToolbar(on screen: NSScreen?) {
        lastScreen = screen
        let panel = CaptureKeyablePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = Self.toolbarLevel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.close() }

        let view = RecordingToolbarView(
            model: model,
            onStart: { [weak self] in self?.start() },
            onSelectDisplay: { [weak self] displayID in self?.selectDisplay(displayID) },
            onSizeChange: { [weak self] size in self?.fitToolbar(to: size) },
            onClose: { [weak self] in self?.close() }
        )
        let hostingView = NSHostingView(rootView: view)
        // The panel is sized by `fitToolbar(to:)` from the size the toolbar actually draws at.
        // Letting SwiftUI resize the window itself (the default) made it shrink on every update.
        hostingView.sizingOptions = []
        let size = hostingView.fittingSize
        hostingView.frame.size = size
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        panel.setFrame(RecordingStopToolbarController.frame(for: size, on: screen), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        toolbarPanel = panel
    }

    // MARK: - Modes

    private func applyMode() {
        switch model.mode {
        case .area:
            overlays.forEach { overlay in
                overlay.selectionView.mode = .area
                overlay.orderFrontRegardless()
            }
        case .fullScreen:
            overlays.forEach { overlay in
                overlay.selectionView.mode = .fullScreen(
                    isTarget: overlay.targetScreen.captureDisplayID == fullScreenTarget?.captureDisplayID
                )
                overlay.orderFrontRegardless()
            }
        case .app:
            // Let the user see the app windows; the toolbar stays up.
            overlays.forEach { $0.orderOut(nil) }
        }
        toolbarPanel?.orderFrontRegardless()
    }

    private func selectionChanged(on overlay: RecordingOverlayWindow, hasSelection: Bool) {
        if hasSelection {
            for other in overlays where other !== overlay {
                other.selectionView.clearSelection()
            }
        }
        model.hasSelection = overlays.contains { $0.selectionView.selectionRect != nil }
        if hasSelection, let rect = overlay.selectionView.selectionRect,
           let displayID = overlay.targetScreen.captureDisplayID {
            lastSelection = (displayID, rect)
        }
    }

    /// Restores the last area. With none (or if its display is gone), preselects a centered area
    /// 60% of the size of the screen under the mouse.
    private func restoreLastSelection(fallbackScreen: NSScreen?) {
        if let lastSelection,
           let overlay = overlays.first(where: { $0.targetScreen.captureDisplayID == lastSelection.displayID }),
           overlay.selectionView.bounds.contains(lastSelection.rect) {
            overlay.selectionView.setSelection(lastSelection.rect)
            model.hasSelection = true
            return
        }
        guard let overlay = overlays.first(where: { $0.targetScreen.captureDisplayID == fallbackScreen?.captureDisplayID })
            ?? overlays.first else { return }
        let bounds = overlay.selectionView.bounds
        let size = CGSize(width: bounds.width * 0.6, height: bounds.height * 0.6)
        let rect = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral
        overlay.selectionView.setSelection(rect)
        model.hasSelection = true
    }

    // MARK: - Start

    private func start() {
        guard model.canStart, let target = currentTarget() else { return }
        let onStart = self.onStart
        let recordAudio = model.recordAudio
        // Area and full-screen recordings start from a clean desktop (unless turned off in
        // Settings): hide the open apps (and Toolkit's windows). The recording brings them back when
        // it stops. Recording an app needs its windows, so nothing is hidden then.
        var hiddenApps = MinimizedApps()
        if hidesApps && model.mode != .app {
            hiddenApps = MinimizedApps.hideAll()
            // Activating the previous app would unhide it again.
            previousFrontApp = nil
        }
        close()
        onStart?(target, hiddenApps, recordAudio)
    }

    /// Picked from the Full Screen dropdown: record that display.
    private func selectDisplay(_ displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { $0.captureDisplayID == displayID }) else { return }
        fullScreenTarget = screen
        if model.mode == .fullScreen {
            applyMode()
        } else {
            model.mode = .fullScreen
        }
    }

    private func currentTarget() -> RecordingTarget? {
        switch model.mode {
        case .area:
            guard let overlay = overlays.first(where: { $0.selectionView.selectionRect != nil }),
                  let rect = overlay.selectionView.selectionRect,
                  let displayID = overlay.targetScreen.captureDisplayID else { return nil }
            // View coordinates have a bottom-left origin; ScreenCaptureKit wants top-left.
            let height = overlay.selectionView.bounds.height
            let flipped = CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
            return .area(displayID: displayID, rect: flipped)
        case .fullScreen:
            guard let displayID = (fullScreenTarget ?? NSScreen.main)?.captureDisplayID else { return nil }
            return .display(displayID: displayID)
        case .app:
            guard let app = model.selectedApp,
                  let displayID = (toolbarPanel?.screen ?? fullScreenTarget ?? NSScreen.main)?.captureDisplayID else { return nil }
            return .application(pid: app.id, preferredDisplayID: displayID)
        }
    }

    // MARK: - Keys

    private func installKeyMonitors() {
        removeKeyMonitors()

        // Esc while another app keeps keyboard focus (needs Accessibility, which Toolkit already has).
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Int(event.keyCode) == kVK_Escape else { return }
            MainActor.assumeIsolated {
                self?.close()
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                MainActor.assumeIsolated { self?.close() }
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                MainActor.assumeIsolated { self?.start() }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitors() {
        for monitor in [globalKeyMonitor, localKeyMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        globalKeyMonitor = nil
        localKeyMonitor = nil
    }
}

extension NSScreen {
    var captureDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}

// MARK: - Overlay

private final class RecordingOverlayWindow: NSPanel {
    let targetScreen: NSScreen
    let selectionView: RecordingSelectionView

    init(screen: NSScreen, level: NSWindow.Level) {
        targetScreen = screen
        selectionView = RecordingSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = selectionView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
}

private final class RecordingSelectionView: NSView {
    enum Mode: Equatable {
        case area
        case fullScreen(isTarget: Bool)
    }

    var mode: Mode = .area {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    private(set) var selectionRect: CGRect?
    var onSelectionChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    private var dragOrigin: CGPoint?
    private var moveStart: (mouse: CGPoint, rect: CGRect)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func cursorUpdate(with event: NSEvent) {
        if mode == .area {
            let point = convert(event.locationInWindow, from: nil)
            if let corner = corner(at: point) {
                NSCursor.frameResize(position: corner.position, directions: .all).set()
            } else if let rect = selectionRect, rect.contains(point) {
                NSCursor.openHand.set()
            } else {
                NSCursor.crosshair.set()
            }
        } else {
            NSCursor.pointingHand.set()
        }
    }

    /// Open hand over the selection (it can be dragged), crosshair elsewhere.
    override func mouseMoved(with event: NSEvent) {
        cursorUpdate(with: event)
    }

    private static let handleSize: CGFloat = 8
    private static let cornerHitRadius: CGFloat = 10

    /// The selection corner under `point`, with the opposite corner (the fixed anchor for resizing).
    private func corner(at point: CGPoint) -> (anchor: CGPoint, position: NSCursor.FrameResizePosition)? {
        guard let rect = selectionRect else { return nil }
        // View coordinates have a bottom-left origin, so maxY is the top edge.
        let corners: [(CGPoint, CGPoint, NSCursor.FrameResizePosition)] = [
            (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.minY), .topLeft),
            (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY), .topRight),
            (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), .bottomLeft),
            (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), .bottomRight),
        ]
        for (corner, anchor, position) in corners
        where abs(point.x - corner.x) <= Self.cornerHitRadius && abs(point.y - corner.y) <= Self.cornerHitRadius {
            return (anchor, position)
        }
        return nil
    }

    func setSelection(_ rect: CGRect) {
        selectionRect = rect
        needsDisplay = true
    }

    func clearSelection() {
        guard selectionRect != nil else { return }
        selectionRect = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard mode == .area else {
            onClick?()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        // Pressing on a corner resizes the selection: it's redrawn from the opposite corner.
        if let corner = corner(at: point) {
            moveStart = nil
            dragOrigin = corner.anchor
            return
        }
        // Pressing inside the current selection moves it; pressing outside clears it (a tap leaves
        // nothing selected, a drag draws a new area).
        if let rect = selectionRect, rect.contains(point) {
            moveStart = (mouse: point, rect: rect)
            dragOrigin = nil
            NSCursor.closedHand.set()
            return
        }
        moveStart = nil
        dragOrigin = point
        selectionRect = nil
        needsDisplay = true
        onSelectionChanged?(false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let moveStart {
            var rect = moveStart.rect.offsetBy(dx: point.x - moveStart.mouse.x, dy: point.y - moveStart.mouse.y)
            rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
            rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
            selectionRect = rect.integral
            needsDisplay = true
            return
        }
        guard let dragOrigin else { return }
        let clamped = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
        selectionRect = CGRect(
            x: min(dragOrigin.x, clamped.x),
            y: min(dragOrigin.y, clamped.y),
            width: abs(clamped.x - dragOrigin.x),
            height: abs(clamped.y - dragOrigin.y)
        ).integral
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area else { return }
        if moveStart != nil {
            moveStart = nil
            window?.invalidateCursorRects(for: self)
            NSCursor.openHand.set()
            onSelectionChanged?(selectionRect != nil)
            return
        }
        dragOrigin = nil
        if let rect = selectionRect, rect.width < 8 || rect.height < 8 {
            selectionRect = nil
            needsDisplay = true
        }
        onSelectionChanged?(selectionRect != nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.35)

        switch mode {
        case .area:
            dim.setFill()
            bounds.fill()
            guard let rect = selectionRect else { return }
            NSColor.clear.setFill()
            rect.fill(using: .copy)

            let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.white.setStroke()
            border.stroke()

            drawSizeLabel(for: rect)
            drawCornerHandles(for: rect)

        case .fullScreen(let isTarget):
            if isTarget {
                let border = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
                border.lineWidth = 4
                NSColor.controlAccentColor.setStroke()
                border.stroke()
            } else {
                dim.setFill()
                bounds.fill()
                drawHint("Click to record this screen instead")
            }
        }
    }

    /// Small squares on the corners show where the area can be resized.
    private func drawCornerHandles(for rect: CGRect) {
        let half = Self.handleSize / 2
        for corner in [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ] {
            let handle = NSBezierPath(
                roundedRect: CGRect(x: corner.x - half, y: corner.y - half, width: Self.handleSize, height: Self.handleSize),
                xRadius: 2, yRadius: 2
            )
            NSColor.white.setFill()
            handle.fill()
            NSColor.black.withAlphaComponent(0.4).setStroke()
            handle.lineWidth = 1
            handle.stroke()
        }
    }

    private func drawSizeLabel(for rect: CGRect) {
        let scale = window?.backingScaleFactor ?? 2
        let text = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        var origin = CGPoint(x: rect.minX, y: rect.minY - size.height - 10)
        if origin.y < bounds.minY + 4 {
            origin.y = rect.minY + 6
            origin.x += 6
        }
        let background = CGRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: background, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: origin.x + 6, y: origin.y + 3), withAttributes: attributes)
    }

    private func drawHint(_ hint: String) {
        let text = hint as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

// MARK: - Toolbar view

private struct RecordingToolbarView: View {
    @ObservedObject var model: RecordingToolbarModel
    let onStart: () -> Void
    let onSelectDisplay: (CGDirectDisplayID) -> Void
    let onSizeChange: (CGSize) -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            CaptureCloseButton(action: onClose)
                .padding(.horizontal, 4)

            ToolbarDivider()

            ToolbarModeButton(
                title: "Selected Area",
                systemImage: "rectangle.dashed",
                isSelected: model.mode == .area
            ) {
                model.mode = .area
            }

            if model.displays.count > 1 {
                displayMenu
            } else {
                ToolbarModeButton(
                    title: "Full Screen",
                    systemImage: "menubar.dock.rectangle",
                    isSelected: model.mode == .fullScreen
                ) {
                    model.mode = .fullScreen
                }
            }

            Menu {
                if model.apps.isEmpty {
                    Text("No open apps")
                }
                ForEach(model.apps) { app in
                    Button {
                        model.selectedApp = app
                        model.mode = .app
                    } label: {
                        Label {
                            Text(app.name)
                        } icon: {
                            Image(nsImage: app.icon)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 12, weight: .medium))
                    Text(Self.shortened(model.selectedApp?.name ?? "App"))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(model.mode == .app ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(model.mode == .app ? Color.accentColor : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()

            ToolbarDivider()

            Toggle(isOn: $model.recordAudio) {
                Text("Record Audio")
                    .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 6)
            .fixedSize()
            .help("Record system audio along with the video")

            Button(action: onStart) {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Start Recording")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.red.opacity(model.canStart ? 1 : 0.4))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canStart)
            .help(model.canStart ? "Start recording (Return)" : startHint)
        }
        // Always lay out at the natural width so labels are never squeezed or truncated.
        .fixedSize()
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
    }

    /// With more than one display, Full Screen becomes a dropdown for picking which one to record.
    private var displayMenu: some View {
        Menu {
            ForEach(model.displays) { display in
                Button {
                    onSelectDisplay(display.id)
                } label: {
                    if display.id == model.selectedDisplayID {
                        Label(display.name, systemImage: "checkmark")
                    } else {
                        Text(display.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "display")
                    .font(.system(size: 12, weight: .medium))
                Text(Self.shortened(model.displays.first(where: { $0.id == model.selectedDisplayID })?.name ?? "Display"))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(model.mode == .fullScreen ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(model.mode == .fullScreen ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Record a full display")
    }

    /// The toolbar lays out at its natural width, so very long names are cut short here.
    private static func shortened(_ name: String, limit: Int = 22) -> String {
        name.count > limit ? String(name.prefix(limit - 1)) + "…" : name
    }

    private var startHint: String {
        switch model.mode {
        case .area: return "Drag on the screen to select an area first"
        case .app: return "Pick an app first"
        case .fullScreen: return ""
        }
    }
}

private struct ToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 4)
    }
}

private struct ToolbarModeButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.08) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

extension RecordingToolbarController {
    /// Makes the panel exactly as big as the drawn toolbar and centers it on its screen. Uses the
    /// size SwiftUI reports for the toolbar itself, so the window never ends up wider or narrower
    /// than what's visible (which made it look off-center).
    fileprivate func fitToolbar(to size: CGSize) {
        guard let panel = toolbarPanel, size.width > 0, size.height > 0 else { return }
        let size = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        let frame = RecordingStopToolbarController.frame(for: size, on: lastScreen)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
    }
}
