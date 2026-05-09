import AppKit
import Combine
import SwiftUI

@MainActor
final class SystemHealthFeature: NSObject, AppFeature, NSPopoverDelegate {
    let id = "system-health"

    private let monitor = SystemHealthMonitor()
    private let model = SystemHealthModel()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private weak var popoverWindow: NSWindow?
    private var popoverResignObserver: NSObjectProtocol?
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
        removePopoverResignObserver()
        popover?.performClose(nil)
        popover = nil

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
        let image = NSImage(size: canvasSize)
        image.lockFocus()
        color.setFill()
        let dotRect = NSRect(
            x: (canvasSize.width - dotDiameter) / 2,
            y: (canvasSize.height - dotDiameter) / 2,
            width: dotDiameter,
            height: dotDiameter
        )
        NSBezierPath(ovalIn: dotRect).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    @objc
    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover?.isShown == true {
            popover?.performClose(sender)
            return
        }

        refreshSnapshot()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 430, height: 272)
        popover.contentViewController = NSHostingController(
            rootView: SystemHealthPopoverView(model: model)
        )
        self.popover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        focusPopoverWindow()
    }

    private func focusPopoverWindow() {
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let window = self.popover?.contentViewController?.view.window else { return }

            self.popoverWindow = window
            self.installPopoverResignObserver(for: window)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func installPopoverResignObserver(for window: NSWindow) {
        removePopoverResignObserver()
        popoverResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.popover?.performClose(nil)
        }
    }

    private func removePopoverResignObserver() {
        if let popoverResignObserver {
            NotificationCenter.default.removeObserver(popoverResignObserver)
            self.popoverResignObserver = nil
        }
        popoverWindow = nil
    }

    nonisolated func popoverWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.removePopoverResignObserver()
        }
    }
}

@MainActor
final class SystemHealthModel: ObservableObject {
    @Published var snapshot: SystemHealthSnapshot = .empty
}
