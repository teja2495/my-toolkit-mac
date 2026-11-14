import AppKit
import Combine
import SwiftUI

@MainActor
final class RecordingCountdownModel: ObservableObject {
    @Published var remaining = 0
    @Published var appsMinimized = false
    /// Recording an app needs its windows, so minimizing is offered for area and full-screen only.
    @Published var canMinimize = true
}

/// A short countdown shown before a recording starts, in the same spot as the recording toolbar,
/// so the user can get things ready. Offers to minimize the open apps (they come back when the
/// recording ends), start right away, or cancel. Toolkit's windows are excluded from the capture,
/// so it never appears in the video.
@MainActor
final class RecordingCountdownController {
    static let seconds = 5
    private static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    private let model = RecordingCountdownModel()
    private var panel: NSPanel?
    private var timer: Timer?
    private var minimizedApps = MinimizedApps()
    private var onFinish: ((MinimizedApps) -> Void)?
    private var onCancel: (() -> Void)?

    var isVisible: Bool { panel != nil }

    /// `onFinish` gets the apps minimized from the countdown; the caller restores them once the
    /// recording ends. On cancel, anything minimized here is brought back first.
    func show(
        on screen: NSScreen?,
        canMinimize: Bool,
        onFinish: @escaping (MinimizedApps) -> Void,
        onCancel: @escaping () -> Void
    ) {
        tearDown()
        restoreMinimizedApps()
        self.onFinish = onFinish
        self.onCancel = onCancel
        model.remaining = Self.seconds
        model.appsMinimized = false
        model.canMinimize = canMinimize

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

        let view = RecordingCountdownView(
            model: model,
            onToggleMinimize: { [weak self] in self?.toggleMinimize() },
            onStartNow: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.cancel() }
        )
        let hostingView = CountdownHostingView(rootView: view)
        // Fixed size: the countdown digit changing must not resize the panel.
        hostingView.sizingOptions = []
        let size = hostingView.fittingSize
        hostingView.frame.size = size
        panel.contentView = hostingView
        panel.setFrame(RecordingStopToolbarController.frame(for: size, on: screen), display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops the countdown without recording and brings back any apps minimized from it.
    func cancel() {
        guard isVisible else { return }
        let onCancel = self.onCancel
        tearDown()
        restoreMinimizedApps()
        onCancel?()
    }

    private func tick() {
        model.remaining -= 1
        if model.remaining <= 0 {
            finish()
        }
    }

    private func finish() {
        guard isVisible else { return }
        let onFinish = self.onFinish
        let minimized = minimizedApps
        minimizedApps = MinimizedApps()
        tearDown()
        onFinish?(minimized)
    }

    private func toggleMinimize() {
        if model.appsMinimized {
            restoreMinimizedApps()
        } else {
            minimizedApps = MinimizedApps.hideAll()
            model.appsMinimized = true
        }
    }

    private func restoreMinimizedApps() {
        let minimized = minimizedApps
        minimizedApps = MinimizedApps()
        model.appsMinimized = false
        minimized.restore()
    }

    private func tearDown() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        onFinish = nil
        onCancel = nil
    }
}

/// Toolkit usually isn't the active app during the countdown; without this the first click on a
/// button would only focus the panel.
private final class CountdownHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct RecordingCountdownView: View {
    @ObservedObject var model: RecordingCountdownModel
    let onToggleMinimize: () -> Void
    let onStartNow: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            CaptureCloseButton(action: onCancel)
                .help("Cancel recording")
                .padding(.horizontal, 4)

            HStack(spacing: 8) {
                Image(systemName: "record.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                Text("Recording in")
                    .font(.system(size: 12, weight: .medium))
                Text("\(max(model.remaining, 0))")
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .frame(width: 14)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: model.remaining)
            }
            .padding(.horizontal, 8)

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 20)
                .padding(.horizontal, 4)

            if model.canMinimize {
                CountdownButton(
                    title: model.appsMinimized ? "Restore Apps" : "Minimize Apps",
                    systemImage: model.appsMinimized ? "macwindow.on.rectangle" : "rectangle.compress.vertical",
                    isProminent: false,
                    action: onToggleMinimize
                )
                .help(model.appsMinimized
                      ? "Bring the minimized apps back"
                      : "Hide open apps; they come back when the recording stops")
            }

            CountdownButton(
                title: "Start Now",
                systemImage: "play.fill",
                isProminent: true,
                action: onStartNow
            )
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

private struct CountdownButton: View {
    let title: String
    let systemImage: String
    let isProminent: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(isProminent ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isProminent {
            return isHovered ? Color.red.opacity(0.85) : Color.red
        }
        return isHovered ? Color.primary.opacity(0.08) : Color.clear
    }
}
