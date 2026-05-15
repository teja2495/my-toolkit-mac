import Foundation
import IOKit.hid

@MainActor
final class MiscellaneousFeature: AppFeature {
    let id = "miscellaneous"

    var reversePhysicalMouseScrollEnabled: Bool = true {
        didSet {
            applyScrollDirectionPolicy()
        }
    }

    private static let scrollDirectionKey = "com.apple.swipescrolldirection" as CFString
    private static let mouseDeviceMatchingCallback: IOHIDDeviceCallback = { context, _, _, _ in
        guard let context else { return }
        let feature = Unmanaged<MiscellaneousFeature>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in
            feature.refreshConnectedMouseCount()
        }
    }

    private var hidManager: IOHIDManager?
    private var connectedMouseCount = 0
    private var capturedInitialScrollDirection: Bool?
    private var didCaptureInitialScrollDirection = false
    private var isApplyingScrollDirectionOverride = false

    func start() {
        guard hidManager == nil else {
            applyScrollDirectionPolicy()
            return
        }

        setupMouseDeviceMonitor()
        refreshConnectedMouseCount()
        applyScrollDirectionPolicy()
    }

    func stop() {
        teardownMouseDeviceMonitor()
        restoreInitialScrollDirectionIfNeeded()
        connectedMouseCount = 0
    }

    private func setupMouseDeviceMonitor() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse
        ]

        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.mouseDeviceMatchingCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.mouseDeviceMatchingCallback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return
        }

        hidManager = manager
    }

    private func teardownMouseDeviceMonitor() {
        guard let manager = hidManager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = nil
    }

    private func refreshConnectedMouseCount() {
        guard let hidManager else {
            connectedMouseCount = 0
            applyScrollDirectionPolicy()
            return
        }

        let deviceSet = IOHIDManagerCopyDevices(hidManager) as NSSet?
        connectedMouseCount = deviceSet?.count ?? 0
        applyScrollDirectionPolicy()
    }

    private func applyScrollDirectionPolicy() {
        let shouldReverseScrollDirection = reversePhysicalMouseScrollEnabled && connectedMouseCount > 0

        if shouldReverseScrollDirection {
            if !isApplyingScrollDirectionOverride {
                captureInitialScrollDirectionIfNeeded()
            }
            writeScrollDirectionPreference(isNatural: false)
            isApplyingScrollDirectionOverride = true
            return
        }

        restoreInitialScrollDirectionIfNeeded()
    }

    private func captureInitialScrollDirectionIfNeeded() {
        guard !didCaptureInitialScrollDirection else { return }
        capturedInitialScrollDirection = readScrollDirectionPreference()
        didCaptureInitialScrollDirection = true
    }

    private func restoreInitialScrollDirectionIfNeeded() {
        guard isApplyingScrollDirectionOverride else { return }
        writeScrollDirectionPreference(isNatural: capturedInitialScrollDirection)
        isApplyingScrollDirectionOverride = false
        didCaptureInitialScrollDirection = false
        capturedInitialScrollDirection = nil
    }

    private func readScrollDirectionPreference() -> Bool? {
        CFPreferencesCopyValue(
            Self.scrollDirectionKey,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? Bool
    }

    private func writeScrollDirectionPreference(isNatural: Bool?) {
        let value: CFBoolean? = isNatural.map { $0 as CFBoolean }
        CFPreferencesSetValue(
            Self.scrollDirectionKey,
            value,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        _ = CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }
}
