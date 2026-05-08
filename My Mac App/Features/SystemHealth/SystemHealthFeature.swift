import AppKit
import Combine
import SwiftUI

@MainActor
final class SystemHealthFeature: AppFeature {
    let id = "system-health"

    private let monitor = SystemHealthMonitor()
    private let model = SystemHealthModel()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
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
        updateStatusDot(for: snapshot.needsAttention ? .attention : .good)
    }

    private func updateStatusDot(for status: SystemHealthStatus) {
        let color: NSColor = status == .good ? .systemGreen : .systemOrange
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
        popover.contentSize = NSSize(width: 290, height: 262)
        popover.contentViewController = NSHostingController(
            rootView: SystemHealthPopoverView(model: model)
        )
        self.popover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
}

@MainActor
final class SystemHealthModel: ObservableObject {
    @Published var snapshot: SystemHealthSnapshot = .empty
}
