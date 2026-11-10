import AppKit
import SwiftUI

/// The toolbar shown while a recording runs: just a Stop Recording button with the elapsed time,
/// in the same spot as the recording toolbar. Toolkit's windows are excluded from the capture,
/// so it never appears in the video.
@MainActor
final class RecordingStopToolbarController {
    private static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    private var panel: NSPanel?

    func show(on screen: NSScreen?, startDate: Date, onStop: @escaping () -> Void) {
        close()

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = Self.level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let hostingView = FirstClickHostingView(rootView: RecordingStopToolbarView(startDate: startDate, onStop: onStop))
        let size = hostingView.fittingSize
        hostingView.frame.size = size
        panel.contentView = hostingView

        panel.setFrame(Self.frame(for: size, on: screen), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Where both recording toolbars sit: centered horizontally, with the bottom edge 5% of the
    /// screen's height above the bottom of the screen.
    static func frame(for size: CGSize, on screen: NSScreen?) -> CGRect {
        let bounds = (screen ?? NSScreen.main)?.frame ?? CGRect(origin: .zero, size: size)
        return CGRect(
            x: (bounds.midX - size.width / 2).rounded(),
            y: (bounds.minY + bounds.height * 0.05).rounded(),
            width: size.width,
            height: size.height
        )
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Toolkit usually isn't the active app while recording; without this the first click on the
/// button would only focus the panel.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct RecordingStopToolbarView: View {
    let startDate: Date
    let onStop: () -> Void

    var body: some View {
        Button(action: onStop) {
            HStack(spacing: 8) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Stop Recording")
                    .font(.system(size: 12, weight: .semibold))
                TimelineView(.periodic(from: startDate, by: 1)) { context in
                    Text(Self.elapsed(from: startDate, to: context.date))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.red)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Stop recording (\(ScreenCaptureFeature.recordingSymbol))")
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
