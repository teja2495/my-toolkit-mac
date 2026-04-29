import AppKit
import SwiftUI

@MainActor
final class DockWindowPopupController {
    private let panel: NSPanel
    private let hostingController: NSHostingController<DockWindowPopupView>

    init() {
        let rootView = DockWindowPopupView(appName: "", windowTitles: [])
        hostingController = NSHostingController(rootView: rootView)
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        panel.contentViewController = hostingController
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
    }

    var isVisible: Bool { panel.isVisible }
    var frameOnScreen: CGRect { panel.frame }

    func show(for app: DockHoveredApplication, windowTitles: [String]) {
        hostingController.rootView = DockWindowPopupView(
            appName: app.displayName,
            windowTitles: windowTitles
        )

        let panelSize = preferredSize(for: windowTitles)
        panel.setFrame(frame(for: panelSize, anchoredTo: app.dockItemFrame), display: true)
        panel.orderFrontRegardless()
    }

    func updateContent(appName: String, windowTitles: [String]) {
        hostingController.rootView = DockWindowPopupView(
            appName: appName,
            windowTitles: windowTitles
        )
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func preferredSize(for windowTitles: [String]) -> CGSize {
        let visibleRows = max(1, min(windowTitles.count, 8))
        let height = CGFloat(56 + (visibleRows * 24))
        return CGSize(width: 320, height: height)
    }

    private func frame(for size: CGSize, anchoredTo dockItemFrame: CGRect) -> CGRect {
        let anchorMidX = dockItemFrame.midX
        let anchorTop = dockItemFrame.maxY

        let visibleFrame = NSScreen.screens
            .first(where: { $0.frame.intersects(dockItemFrame) })?
            .visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 720)

        var origin = CGPoint(
            x: anchorMidX - (size.width / 2),
            y: anchorTop + 12
        )

        if origin.x < visibleFrame.minX + 8 {
            origin.x = visibleFrame.minX + 8
        }

        if origin.x + size.width > visibleFrame.maxX - 8 {
            origin.x = visibleFrame.maxX - size.width - 8
        }

        if origin.y + size.height > visibleFrame.maxY - 8 {
            origin.y = dockItemFrame.minY - size.height - 12
        }

        if origin.y < visibleFrame.minY + 8 {
            origin.y = visibleFrame.minY + 8
        }

        return CGRect(origin: origin, size: size)
    }
}

private struct DockWindowPopupView: View {
    let appName: String
    let windowTitles: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appName)
                .font(.headline)
                .lineLimit(1)

            if windowTitles.isEmpty {
                Text("No open windows with visible titles")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(windowTitles.prefix(8)), id: \.self) { title in
                    HStack(spacing: 8) {
                        Image(systemName: "macwindow")
                            .foregroundStyle(.secondary)
                        Text(title)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline)
                    .contentShape(Rectangle())
                }
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}
