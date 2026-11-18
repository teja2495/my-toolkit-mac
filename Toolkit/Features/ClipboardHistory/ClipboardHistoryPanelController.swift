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
    private let onCopy: ([ClipboardHistoryItem]) -> Bool
    private var hostingController: NSHostingController<ClipboardHistoryView>?
    private var pasteTarget: NSRunningApplication?
    private var keyMonitor: Any?
    private let viewModel = ClipboardHistoryViewModel()

    init(store: ClipboardHistoryStore, onCopy: @escaping ([ClipboardHistoryItem]) -> Bool) {
        self.store = store
        self.onCopy = onCopy
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.defaultPanelSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
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
            show(minimizingMainWindow: true)
        }
    }

    func show(minimizingMainWindow: Bool = false) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        pasteTarget = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost

        if minimizingMainWindow {
            let mainWindows = NSApp.windows.filter { $0.identifier == ToolkitApp.mainWindowIdentifier }
            for window in mainWindows where window.isVisible && !window.isMiniaturized {
                window.miniaturize(nil)
            }
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
        viewModel.renamingID = nil

        panel.setFrame(centeredFrame(), display: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func close() {
        removeKeyMonitor()
        pasteTarget = nil
        panel.orderOut(nil)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // While a row is being renamed, let the text field receive every key.
            guard let self, event.window === self.panel, self.viewModel.renamingID == nil,
                  let key = Self.key(for: event) else { return event }
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
            return modifiers.isEmpty ? .paste : nil
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
        pasteTarget = nil
    }

    private func copyOnly(_ items: [ClipboardHistoryItem]) {
        _ = onCopy(items)
        close()
    }

    /// Copies the selection before letting the previous app handle Paste.
    private func paste(_ items: [ClipboardHistoryItem]) {
        let target = pasteTarget
        let copied = onCopy(items)
        let changeCount = NSPasteboard.general.changeCount
        close()
        guard copied, let target, AXIsProcessTrusted() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard self?.isVisible == false,
                  NSPasteboard.general.changeCount == changeCount,
                  NSWorkspace.shared.frontmostApplication == target else { return }
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
        case up, down, paste, delete, clearSelection, close
    }

    @Published var selectedID: ClipboardHistoryItem.ID?
    /// Items picked with ⌘-click, in the order they were picked.
    @Published var multiSelectedIDs: [ClipboardHistoryItem.ID] = []
    /// Item whose title is currently being edited inline.
    @Published var renamingID: ClipboardHistoryItem.ID?
    /// Set by the view; returns true when the key was handled.
    var keyHandler: ((Key) -> Bool)?
}
