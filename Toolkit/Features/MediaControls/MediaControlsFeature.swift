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

    private let client = MediaRemoteClient()
    private lazy var model = MediaControlsModel(client: client)
    private var statusItem: NSStatusItem?
    private var panel: MediaControlsPanel?
    private var refreshTimer: Timer?
    private var hoverTimer: Timer?
    private var closeWorkItem: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var statusVisibilityCancellable: AnyCancellable?
    private var nowPlayingCancellable: AnyCancellable?
    private var isStatusButtonHovered = false
    private var isNotchHovered = false
    private var isPanelHovered = false
    private var currentHoverScreen: NSScreen?

    private let notchActivationWidth: CGFloat = 270
    private let notchPollingHeight: CGFloat = 86
    private let panelTopOffset: CGFloat = 32

    func start() {
        guard refreshTimer == nil else { return }

        ensureStatusItem()
        client.registerForUpdates { [weak self] info in
            Task { @MainActor [weak self] in
                self?.model.receive(info)
                self?.syncStatusItemVisibility()
            }
        }
        installObservers()
        installStatusVisibilityObserver()
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
        startNotchHoverPolling()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        removeScreenObserver()
        statusVisibilityCancellable = nil
        nowPlayingCancellable = nil
        removeObservers()
        client.stopStreaming()
        closePanel()
        removeStatusItem()
        isStatusButtonHovered = false
        isNotchHovered = false
        currentHoverScreen = nil
    }

    @objc
    func mouseEntered(with event: NSEvent) {
        isStatusButtonHovered = true
        cancelScheduledClose()
        showPanel()
    }

    @objc
    func mouseExited(with event: NSEvent) {
        isStatusButtonHovered = false
        scheduleCloseIfNeeded()
    }

    @objc
    private func togglePause(_ sender: NSStatusBarButton) {
        model.togglePlayPause()
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
            self?.syncStatusItemVisibility()
        }
    }

    private func syncStatusItemVisibility() {
        ensureStatusItem()
        updateStatusItemIcon()

        if !model.hasMedia, !isStatusButtonHovered, !isNotchHovered, !isPanelHovered {
            closePanel()
        }
    }

    private func installStatusVisibilityObserver() {
        statusVisibilityCancellable = model.$isPlaybackActive
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.syncStatusItemVisibility()
            }
        nowPlayingCancellable = model.$nowPlaying
            .sink { [weak self] _ in
                self?.syncStatusItemVisibility()
            }
    }

    private func ensureStatusItem() {
        guard statusItem == nil else {
            updateStatusItemIcon()
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePause(_:))
        item.button?.toolTip = "Pause media"
        statusItem = item
        updateStatusItemIcon()
        installStatusButtonTrackingArea()
    }

    private func updateStatusItemIcon() {
        guard let button = statusItem?.button else { return }
        let symbolName: String
        if model.hasMedia {
            symbolName = model.isPlaying ? "pause.fill" : "play.fill"
        } else {
            symbolName = "music.note"
        }
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Media Controls")
        button.imagePosition = .imageOnly
        if model.hasMedia {
            button.toolTip = model.isPlaying ? "Pause media" : "Play media"
        } else {
            button.toolTip = "Media controls"
        }
    }

    private func installStatusButtonTrackingArea() {
        guard let button = statusItem?.button else { return }
        let trackingArea = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        button.addTrackingArea(trackingArea)
    }

    private func removeStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        isStatusButtonHovered = false
    }

    private func showPanel() {
        model.refresh()

        if panel?.isVisible == true { return }

        let screen = currentHoverScreen ?? NSScreen.main
        let panelWidth = min(max((screen?.frame.width ?? 720) * 0.48, 500), 640)
        let rootView = MediaControlsPopoverView(model: model, preferredWidth: panelWidth)
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

    private func position(panel: NSPanel, width: CGFloat, height: CGFloat, screen: NSScreen?) {
        if isStatusButtonHovered,
           let button = statusItem?.button,
           let buttonWindow = button.window {
            let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let screenFrame = button.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let x = min(
                max(buttonRect.midX - width / 2, screenFrame.minX + 8),
                screenFrame.maxX - width - 8
            )
            let y = buttonRect.minY - height - 6
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        guard let screen else {
            panel.center()
            return
        }

        let screenFrame = screen.frame
        let x = min(
            max(screenFrame.midX - width / 2, screenFrame.minX + 12),
            screenFrame.maxX - width - 12
        )
        let y = screenFrame.maxY - panelTopOffset - height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func setNotchHovered(_ isHovered: Bool, screen: NSScreen?) {
        currentHoverScreen = screen ?? currentHoverScreen
        guard isNotchHovered != isHovered else { return }

        isNotchHovered = isHovered
        if isHovered {
            cancelScheduledClose()
            showPanel()
        } else {
            scheduleCloseIfNeeded()
        }
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

    private func pollNotchHoverRegion() {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screenWithMouse else {
            setNotchHovered(false, screen: nil)
            return
        }

        let screenFrame = screen.frame
        let baseX = screenFrame.midX - notchActivationWidth / 2
        let baseY = screenFrame.maxY - notchPollingHeight
        let isHovering = mouseLocation.y >= baseY
            && mouseLocation.x >= baseX
            && mouseLocation.x <= baseX + notchActivationWidth

        setNotchHovered(isHovering, screen: screen)
    }

    private func scheduleCloseIfNeeded() {
        cancelScheduledClose()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isStatusButtonHovered, !self.isNotchHovered, !self.isPanelHovered else { return }
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
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}
