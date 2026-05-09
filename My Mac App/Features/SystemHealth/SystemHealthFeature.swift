import AppKit
import Combine
import SwiftUI

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class SystemHealthFeature: NSObject, AppFeature {
    let id = "system-health"

    private let monitor = SystemHealthMonitor()
    private let model = SystemHealthModel()
    private var statusItem: NSStatusItem?
    private var panel: KeyablePanel?
    private var panelResignObserver: NSObjectProtocol?
    private var refreshTimer: Timer?

    func start() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.toolTip = "System Health"
        statusItem = item

        refreshSnapshot()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot()
            }
        }

        if let refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        closePanel()

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    private func refreshSnapshot() {
        let snapshot = monitor.snapshot()
        model.snapshot = snapshot
        updateStatusDot(for: snapshot.memoryStatus)
    }

    private func updateStatusDot(for status: SystemHealthStatus) {
        let color: NSColor
        switch status {
        case .good:
            color = NSColor(red: 0.22, green: 0.90, blue: 0.54, alpha: 1)
        case .attention:
            color = NSColor(red: 0.95, green: 0.67, blue: 0.25, alpha: 1)
        case .critical:
            color = NSColor(red: 0.88, green: 0.35, blue: 0.35, alpha: 1)
        }
        guard let button = statusItem?.button else { return }

        button.attributedTitle = NSAttributedString(string: "")
        button.image = makeStatusDotImage(color: color)
        button.imagePosition = .imageOnly
    }

    private func makeStatusDotImage(color: NSColor) -> NSImage {
        let canvasSize = NSSize(width: 18, height: 18)
        let dotDiameter: CGFloat = 10
        let dotRect = NSRect(
            x: (canvasSize.width - dotDiameter) / 2,
            y: (canvasSize.height - dotDiameter) / 2,
            width: dotDiameter,
            height: dotDiameter
        )

        let image = NSImage(size: canvasSize, flipped: false) { _ in
            NSColor.clear.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: canvasSize)).fill()

            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc
    private func togglePopover(_ sender: NSStatusBarButton) {
        if let panel = panel, panel.isVisible {
            closePanel()
            return
        }

        refreshSnapshot()
        showPanel()
    }

    private func showPanel() {
        closePanel()

        let panelWidth: CGFloat = 430

        let hostingController = NSHostingController(rootView: SystemHealthPopoverView(model: model))
        let panelHeight = ceil(hostingController.sizeThatFits(in: NSSize(width: panelWidth, height: .greatestFiniteMagnitude)).height)

        let newPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.level = .popUpMenu
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.isReleasedWhenClosed = false
        newPanel.contentViewController = hostingController

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let x = sf.maxX - panelWidth
            if let button = statusItem?.button, let buttonWindow = button.window {
                let buttonRectInScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
                let y = buttonRectInScreen.minY - panelHeight - 6
                newPanel.setFrameOrigin(NSPoint(x: x, y: y))
            } else {
                newPanel.setFrameOrigin(NSPoint(x: x, y: sf.maxY - panelHeight))
            }
        } else {
            newPanel.center()
        }

        self.panel = newPanel
        installPanelResignObserver(for: newPanel)

        newPanel.orderFrontRegardless()
        newPanel.makeKey()
    }

    private func closePanel() {
        removePanelResignObserver()
        panel?.orderOut(nil)
        panel = nil
    }

    private func installPanelResignObserver(for window: NSWindow) {
        removePanelResignObserver()
        panelResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePanel()
            }
        }
    }

    private func removePanelResignObserver() {
        if let panelResignObserver {
            NotificationCenter.default.removeObserver(panelResignObserver)
            self.panelResignObserver = nil
        }
    }
}

@MainActor
final class SystemHealthModel: ObservableObject {
    @Published var snapshot: SystemHealthSnapshot = .empty
}
