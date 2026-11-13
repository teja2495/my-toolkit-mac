import AppKit
import SwiftUI

extension View {
    /// Switches the enclosing scroll view to thin overlay scrollers that fade out when idle,
    /// instead of the always-visible legacy scroll bar macOS shows when a mouse is connected.
    /// Apply to the content inside a `ScrollView`.
    func subtleScrollers() -> some View {
        background(SubtleScrollerConfigurator())
    }
}

private struct SubtleScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerProbeView {
        ScrollerProbeView()
    }

    func updateNSView(_ nsView: ScrollerProbeView, context: Context) {
        nsView.applyStyle()
    }
}

private final class ScrollerProbeView: NSView {
    private var styleObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if styleObserver == nil {
            // macOS resets the style when the user's scroll bar preference or input devices change.
            styleObserver = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.applyStyle() }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.applyStyle()
        }
    }

    func applyStyle() {
        guard let scrollView = enclosingScrollView else { return }
        if scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
        }
        scrollView.autohidesScrollers = true
    }

    deinit {
        if let styleObserver {
            NotificationCenter.default.removeObserver(styleObserver)
        }
    }
}
