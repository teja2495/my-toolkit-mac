import AppKit
import Combine
import SwiftUI

private final class MediaControlsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class HoverTrackingHostingView<Content: View>: NSHostingView<Content> {
    var hoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let newTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newTrackingArea)
        trackingArea = newTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        hoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hoverChanged?(false)
    }
}

@MainActor
final class MediaControlsFeature: NSObject, AppFeature {
    let id = "media-controls"
    var hoverDelay: TimeInterval = 0

    private let client = MediaRemoteClient()
    private lazy var model = MediaControlsModel(client: client)
    private var panel: MediaControlsPanel?
    private var menuBarPanels: [CGDirectDisplayID: MediaControlsPanel] = [:]
    private var refreshTimer: Timer?
    private var hoverTimer: Timer?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var closeWorkItem: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var playbackStateCancellable: AnyCancellable?
    private var nowPlayingCancellable: AnyCancellable?
    private var isNotchHovered = false
    private var isPanelHovered = false
    private var currentHoverScreen: NSScreen?
    private var pendingHoverScreen: NSScreen?
    private var pendingHoverStartDate: Date?

    private let panelTopOffset: CGFloat = 32
    func start() {
        guard refreshTimer == nil else { return }

        client.registerForUpdates { [weak self] info in
            Task { @MainActor [weak self] in
                self?.model.receive(info)
                self?.updateDisplayPresentation()
            }
        }
        installObservers()
        installPanelStateObservers()
        refreshNowPlaying()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNowPlaying()
            }
        }

        if let refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }

        installScreenObserver()
        installNotchClickMonitors()
        startNotchHoverPolling()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        removeNotchClickMonitors()
        removeScreenObserver()
        playbackStateCancellable = nil
        nowPlayingCancellable = nil
        removeObservers()
        client.stopStreaming()
        closePanel()
        removeAllMenuBarPanels()
        isNotchHovered = false
        currentHoverScreen = nil
        pendingHoverScreen = nil
        pendingHoverStartDate = nil
    }

    private func installObservers() {
        guard observers.isEmpty else { return }

        let names = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            "kMRMediaRemoteNowPlayingPlaybackStateDidChangeNotification"
        ]

        observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshNowPlaying()
                }
            }
        }
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func installScreenObserver() {
        guard screenObserver == nil else { return }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                if let panel = self?.panel, self?.isNotchHovered == true {
                    self?.position(
                        panel: panel,
                        width: panel.frame.width,
                        height: panel.frame.height,
                        screen: self?.currentHoverScreen ?? NSScreen.main
                    )
                }
                self?.syncMenuBarPanels(forceLayoutUpdate: true)
            }
        }
    }

    private func removeScreenObserver() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
    }

    private func refreshNowPlaying() {
        model.refresh { [weak self] in
            self?.updateDisplayPresentation()
        }
    }

    private func updateDisplayPresentation() {
        if !model.hasMedia {
            closePanel()
        }
        syncMenuBarPanels()
    }

    private func installPanelStateObservers() {
        playbackStateCancellable = model.$isPlaybackActive
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateDisplayPresentation()
            }
        nowPlayingCancellable = model.$nowPlaying
            .sink { [weak self] _ in
                self?.updateDisplayPresentation()
            }
    }

    private func showPanel() {
        model.refresh()

        if panel?.isVisible == true { return }

        let screen = currentHoverScreen ?? NSScreen.main
        let panelWidth = min(max((screen?.frame.width ?? 720) * 0.48, 500), 640)
        let rootView = VStack(spacing: 0) {
            Color.clear.frame(height: panelTopOffset)
            MediaControlsPopoverView(model: model, preferredWidth: panelWidth)
        }
        let hostingView = HoverTrackingHostingView(rootView: rootView)
        hostingView.hoverChanged = { [weak self] isHovered in
            Task { @MainActor [weak self] in
                self?.isPanelHovered = isHovered
                if isHovered {
                    self?.cancelScheduledClose()
                } else {
                    self?.scheduleCloseIfNeeded()
                }
            }
        }
        let panelHeight = ceil(hostingView.fittingSize.height)

        let newPanel = MediaControlsPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.acceptsMouseMovedEvents = true
        newPanel.ignoresMouseEvents = false
        newPanel.isFloatingPanel = true
        newPanel.level = .mainMenu + 3
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        newPanel.isReleasedWhenClosed = false
        newPanel.contentView = hostingView
        position(panel: newPanel, width: panelWidth, height: panelHeight, screen: screen)

        panel = newPanel
        newPanel.orderFrontRegardless()
    }

    private func syncMenuBarPanels(forceLayoutUpdate: Bool = false) {
        let eligibleScreens = NSScreen.screens.filter { notchRect(for: $0) == nil && menuBarHeight(for: $0) > 0 }
        let eligibleDisplayIDs = Set(eligibleScreens.compactMap(\.displayID))

        let staleDisplayIDs = menuBarPanels.keys.filter { !eligibleDisplayIDs.contains($0) || !model.hasMedia }
        for displayID in staleDisplayIDs {
            menuBarPanels[displayID]?.orderOut(nil)
            menuBarPanels.removeValue(forKey: displayID)
        }

        guard model.hasMedia else { return }

        for screen in eligibleScreens {
            guard let displayID = screen.displayID else { continue }

            let panelHeight = menuBarHeight(for: screen)
            let panelWidth = menuBarPanelWidth(for: panelHeight)
            if let panel = menuBarPanels[displayID] {
                if forceLayoutUpdate
                    || abs(panel.frame.height - panelHeight) > 0.5
                    || abs(panel.frame.width - panelWidth) > 0.5 {
                    panel.contentView = NSHostingView(
                        rootView: MediaControlsMenuBarView(
                            model: model,
                            menuBarHeight: panelHeight
                        )
                    )
                    panel.setContentSize(NSSize(width: panelWidth, height: panelHeight))
                }
                positionMenuBarPanel(panel, screen: screen, width: panelWidth, height: panelHeight)
                if !panel.isVisible {
                    panel.orderFrontRegardless()
                }
                continue
            }

            let newPanel = MediaControlsPanel(
                contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = false
            newPanel.ignoresMouseEvents = false
            newPanel.isFloatingPanel = true
            newPanel.level = .mainMenu + 2
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            newPanel.isReleasedWhenClosed = false
            newPanel.contentView = NSHostingView(
                rootView: MediaControlsMenuBarView(
                    model: model,
                    menuBarHeight: panelHeight
                )
            )
            positionMenuBarPanel(newPanel, screen: screen, width: panelWidth, height: panelHeight)
            menuBarPanels[displayID] = newPanel
            newPanel.orderFrontRegardless()
        }
    }

    private func removeAllMenuBarPanels() {
        for panel in menuBarPanels.values {
            panel.orderOut(nil)
        }
        menuBarPanels.removeAll()
    }

    private func position(panel: NSPanel, width: CGFloat, height: CGFloat, screen: NSScreen?) {
        guard let screen else {
            panel.center()
            return
        }

        let screenFrame = screen.frame
        let x = min(
            max(screenFrame.midX - width / 2, screenFrame.minX + 12),
            screenFrame.maxX - width - 12
        )
        // The transparent top strip keeps the pointer tracked from the notch down to the visible panel.
        let y = screenFrame.maxY - height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func positionMenuBarPanel(_ panel: NSPanel, screen: NSScreen, width: CGFloat, height: CGFloat) {
        let screenFrame = screen.frame
        let x = floor(screenFrame.midX - (width / 2))
        let y = screenFrame.maxY - height
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func menuBarHeight(for screen: NSScreen) -> CGFloat {
        let measuredHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return max(measuredHeight, 24)
    }

    private func menuBarPanelWidth(for height: CGFloat) -> CGFloat {
        max(154, height + 118)
    }

    private func setNotchHovered(_ isHovered: Bool, screen: NSScreen?) {
        if isHovered {
            let resolvedScreen = screen ?? currentHoverScreen
            currentHoverScreen = resolvedScreen ?? currentHoverScreen

            guard hasSatisfiedHoverDelay(for: resolvedScreen) else { return }
            pendingHoverScreen = nil
            pendingHoverStartDate = nil
        } else {
            pendingHoverScreen = nil
            pendingHoverStartDate = nil
            currentHoverScreen = screen ?? currentHoverScreen
        }

        guard isNotchHovered != isHovered else { return }

        isNotchHovered = isHovered
        if isHovered {
            cancelScheduledClose()
            if model.hasMedia {
                showPanel()
            } else {
                closePanel()
            }
        } else {
            scheduleCloseIfNeeded()
        }
    }

    private func hasSatisfiedHoverDelay(for screen: NSScreen?) -> Bool {
        guard hoverDelay > 0 else { return true }

        if pendingHoverScreen !== screen {
            pendingHoverScreen = screen
            pendingHoverStartDate = Date()
            return false
        }

        guard let pendingHoverStartDate else { return false }
        return Date().timeIntervalSince(pendingHoverStartDate) >= hoverDelay
    }

    private func startNotchHoverPolling() {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollNotchHoverRegion()
            }
        }

        if let hoverTimer {
            RunLoop.main.add(hoverTimer, forMode: .common)
        }
    }

    private func installNotchClickMonitors() {
        guard localClickMonitor == nil, globalClickMonitor == nil else { return }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleNotchClick(at: NSEvent.mouseLocation)
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleNotchClick(at: NSEvent.mouseLocation)
            }
        }
    }

    private func removeNotchClickMonitors() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
        localClickMonitor = nil
        globalClickMonitor = nil
    }

    private func handleNotchClick(at mouseLocation: NSPoint) {
        let screen = currentHoverScreen ?? NSScreen.screenWithMouse
        guard let screen,
              let notchRect = notchRect(for: screen),
              notchRect.containsNotchHoverPoint(mouseLocation) else {
            return
        }

        model.togglePlayPause()
    }

    private func pollNotchHoverRegion() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = panel?.isVisible == true ? currentHoverScreen : NSScreen.screenWithMouse
        guard let screen,
              let notchRect = notchRect(for: screen) else {
            setNotchHovered(false, screen: nil)
            if !isMouseOverOpenPanelRegion(mouseLocation) {
                closePanel()
            }
            return
        }

        let isHovering = notchRect.containsNotchHoverPoint(mouseLocation)
            || isMouseOverOpenPanelRegion(mouseLocation)

        setNotchHovered(isHovering, screen: screen)
        if !isHovering {
            closePanel()
        }
    }

    private func notchRect(for screen: NSScreen) -> NSRect? {
        guard screen.safeAreaInsets.top > 0,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else {
            return nil
        }

        let width = rightArea.minX - leftArea.maxX
        guard width > 0 else { return nil }

        return NSRect(
            x: leftArea.maxX,
            y: screen.frame.maxY - screen.safeAreaInsets.top,
            width: width,
            height: screen.safeAreaInsets.top
        )
    }

    private func isMouseOverOpenPanelRegion(_ mouseLocation: NSPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }
        // Once open, keep the full panel-width column active through the screen top.
        return mouseLocation.x >= panel.frame.minX
            && mouseLocation.x <= panel.frame.maxX
            && mouseLocation.y >= panel.frame.minY
    }

    private func scheduleCloseIfNeeded() {
        cancelScheduledClose()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isNotchHovered, !self.isPanelHovered else { return }
                self.closePanel()
            }
        }
        closeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func cancelScheduledClose() {
        closeWorkItem?.cancel()
        closeWorkItem = nil
    }

    private func closePanel() {
        cancelScheduledClose()
        panel?.orderOut(nil)
        panel = nil
        isPanelHovered = false
    }
}

private extension NSScreen {
    static var screenWithMouse: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.containsIncludingEdges(mouseLocation) }
    }

    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private extension NSRect {
    func containsNotchHoverPoint(_ point: NSPoint) -> Bool {
        // macOS may report the pointer above the screen frame while it crosses the physical notch.
        point.x >= minX && point.x <= maxX && point.y >= minY
    }

    func containsIncludingEdges(_ point: NSPoint) -> Bool {
        point.x >= minX && point.x <= maxX
            && point.y >= minY && point.y <= maxY
    }
}
