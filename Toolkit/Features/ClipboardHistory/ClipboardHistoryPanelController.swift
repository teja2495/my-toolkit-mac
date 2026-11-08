import AppKit
import Combine
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class ClipboardHistoryPanelController: NSObject, NSWindowDelegate {
    private static let defaultPanelSize = CGSize(width: 1180, height: 760)
    private static let minimumPanelSize = CGSize(width: 640, height: 380)

    private let panel: NSPanel
    private let store: ClipboardHistoryStore
    private let onCopy: ([ClipboardHistoryItem]) -> Void
    private var hostingController: NSHostingController<ClipboardHistoryView>?
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private let viewModel = ClipboardHistoryViewModel()

    init(store: ClipboardHistoryStore, onCopy: @escaping ([ClipboardHistoryItem]) -> Void) {
        self.store = store
        self.onCopy = onCopy
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.defaultPanelSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.title = "Clipboard History"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.minSize = Self.minimumPanelSize
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible {
            close()
        } else {
            show()
        }
    }

    func show() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }

        if hostingController == nil {
            let view = ClipboardHistoryView(
                store: store,
                model: viewModel,
                onCopy: { [weak self] items in self?.copyOnly(items) },
                onPaste: { [weak self] items in self?.paste(items) },
                onClose: { [weak self] in self?.close() }
            )
            let controller = NSHostingController(rootView: view)
            // Keep SwiftUI from shrinking the panel to the view's ideal size.
            controller.sizingOptions = [.minSize]
            hostingController = controller
            panel.contentViewController = controller
        }

        // Focus the most recent copy, even when pinned items are listed above it.
        viewModel.selectedID = store.items.first(where: { !$0.isPinned })?.id ?? store.items.first?.id
        viewModel.multiSelectedIDs = []

        panel.setFrame(centeredFrame(), display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func close() {
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel, let key = Self.key(for: event) else { return event }
            return self.viewModel.keyHandler?(key) == true ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private static func key(for event: NSEvent) -> ClipboardHistoryViewModel.Key? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_UpArrow where modifiers.isEmpty: return .up
        case kVK_DownArrow where modifiers.isEmpty: return .down
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if modifiers == .command { return .paste }
            return modifiers.isEmpty ? .copy : nil
        case kVK_Delete, kVK_ForwardDelete:
            return modifiers.isEmpty ? .delete : nil
        case kVK_Escape: return .clearSelection
        default: return nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        previousApp = nil
    }

    private func copyOnly(_ items: [ClipboardHistoryItem]) {
        onCopy(items)
        close()
        previousApp?.activate()
    }

    /// Copies the item and pastes it into the app that was frontmost before the panel opened.
    private func paste(_ items: [ClipboardHistoryItem]) {
        onCopy(items)
        close()
        guard let previousApp else { return }
        previousApp.activate()
        guard AXIsProcessTrusted() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Self.postCommandV()
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func centeredFrame() -> CGRect {
        let mouse = NSEvent.mouseLocation
        let visibleFrame = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 720)
        let preferred = Self.defaultPanelSize
        let size = CGSize(
            width: min(preferred.width, visibleFrame.width * 0.92),
            height: min(preferred.height, visibleFrame.height * 0.92)
        )
        return CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

@MainActor
final class ClipboardHistoryViewModel: ObservableObject {
    enum Key {
        case up, down, copy, paste, delete, clearSelection, close
    }

    @Published var selectedID: ClipboardHistoryItem.ID?
    /// Items picked with ⌘-click, in the order they were picked.
    @Published var multiSelectedIDs: [ClipboardHistoryItem.ID] = []
    /// Set by the view; returns true when the key was handled.
    var keyHandler: ((Key) -> Bool)?
}
