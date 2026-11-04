import AppKit
import Carbon.HIToolbox
import Foundation

/// Remaps mouse buttons, modeled on the OpenLogi project's macOS approach:
/// standard buttons are intercepted with a CGEventTap, and the Logitech
/// button near the wheel is diverted over HID++.
@MainActor
final class OpenLogiFeature: AppFeature {
    let id = "openlogi"

    var buttonActions: [OpenLogiButton: MouseButtonAction] = [:] {
        didSet { updateTapState() }
    }

    var doubleClickActions: [OpenLogiButton: MouseButtonAction] = [:] {
        didSet { updateTapState() }
    }

    /// Marks replayed clicks so the tap lets them through.
    private static let syntheticEventMarker: Int64 = 0x4F504C47
    private static let maxDoubleClickInterval: TimeInterval = 0.3

    private var isStarted = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingSingleClicks: [OpenLogiButton: DispatchWorkItem] = [:]
    private lazy var hidppController: LogitechHIDPPController = {
        let controller = LogitechHIDPPController()
        controller.onSmartShiftPressed = { [weak self] in
            self?.buttonPressed(.middle)
        }
        return controller
    }()

    func start() {
        guard !isStarted else { return }
        isStarted = true
        updateTapState()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        cancelPendingClicks()
        removeTap()
        hidppController.stop()
    }

    private func isRemapped(_ button: OpenLogiButton) -> Bool {
        action(for: button) != .systemDefault || doubleClickAction(for: button) != .systemDefault
    }

    private var hasRemappedTapButtons: Bool {
        OpenLogiButton.allCases.contains { $0.buttonNumber != nil && isRemapped($0) }
    }

    private func action(for button: OpenLogiButton) -> MouseButtonAction {
        buttonActions[button] ?? .systemDefault
    }

    private func doubleClickAction(for button: OpenLogiButton) -> MouseButtonAction {
        doubleClickActions[button] ?? .systemDefault
    }

    private func updateTapState() {
        cancelPendingClicks()

        if isStarted && hasRemappedTapButtons {
            installTap()
        } else {
            removeTap()
        }

        if isStarted && isRemapped(.middle) {
            hidppController.start()
        } else {
            hidppController.stop()
        }
    }

    private func installTap() {
        guard eventTap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let feature = Unmanaged<OpenLogiFeature>.fromOpaque(userInfo).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    feature.handle(type: type, event: event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    private func removeTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        guard let button = OpenLogiButton(buttonNumber: buttonNumber), isRemapped(button) else {
            return Unmanaged.passUnretained(event)
        }

        if type == .otherMouseDown {
            DispatchQueue.main.async { [weak self] in
                self?.buttonPressed(button)
            }
        }
        // Swallow down, drag and up events for remapped buttons.
        return nil
    }

    private func buttonPressed(_ button: OpenLogiButton) {
        let doubleAction = doubleClickAction(for: button)
        guard doubleAction != .systemDefault else {
            runSingleClick(for: button)
            return
        }

        if let pending = pendingSingleClicks.removeValue(forKey: button) {
            pending.cancel()
            Self.perform(doubleAction)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSingleClicks[button] = nil
            self.runSingleClick(for: button)
        }
        pendingSingleClicks[button] = workItem
        let interval = min(NSEvent.doubleClickInterval, Self.maxDoubleClickInterval)
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    private func runSingleClick(for button: OpenLogiButton) {
        let singleAction = action(for: button)
        if singleAction == .systemDefault {
            // Only a double-click is mapped: replay the original click.
            if let buttonNumber = button.buttonNumber {
                Self.replayClick(buttonNumber: buttonNumber)
            }
        } else {
            Self.perform(singleAction)
        }
    }

    private func cancelPendingClicks() {
        pendingSingleClicks.values.forEach { $0.cancel() }
        pendingSingleClicks.removeAll()
    }

    private static func replayClick(buttonNumber: Int64) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let mouseButton = CGMouseButton(rawValue: UInt32(buttonNumber)) else { return }
        let location = CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: location,
                mouseButton: mouseButton
            )
            event?.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber)
            event?.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func perform(_ action: MouseButtonAction) {
        switch action {
        case .systemDefault:
            break
        case .copy:
            sendKey(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        case .paste:
            sendKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        case .playPause:
            sendMediaKey(NX_KEYTYPE_PLAY)
        case .missionControl:
            sendDockNotification("com.apple.expose.awake") {
                sendKey(CGKeyCode(kVK_UpArrow), flags: .maskControl)
            }
        case .quitAndReopen:
            quitAndReopenFrontmostApp()
        }
    }

    private static func quitAndReopenFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleURL = app.bundleURL else { return }

        guard app.terminate() else { return }
        Task { @MainActor in
            // Wait up to 10s for the app to quit (it may prompt to save documents).
            for _ in 0..<100 {
                if app.isTerminated { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard app.isTerminated else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
        }
    }

    private typealias CoreDockSendNotificationFn = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void

    private static let coreDockSendNotification: CoreDockSendNotificationFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") else {
            return nil
        }
        return unsafeBitCast(symbol, to: CoreDockSendNotificationFn.self)
    }()

    private static func sendDockNotification(_ name: String, fallback: () -> Void) {
        if let coreDockSendNotification {
            coreDockSendNotification(name as CFString, nil)
        } else {
            fallback()
        }
    }

    private static func sendKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Posts a system media key (e.g. play/pause) the same way the keyboard's media keys do.
    private static func sendMediaKey(_ key: Int32) {
        for isDown in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: isDown ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | ((isDown ? 0xA : 0xB) << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
