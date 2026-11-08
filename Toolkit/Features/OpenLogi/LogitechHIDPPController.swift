import AppKit
import IOKit.hid

/// Minimal HID++ 2.0 client that diverts the Logitech button near the wheel (SmartShift / DPI)
/// so its presses are delivered to the app instead of toggling the wheel ratchet.
///
/// Flow (same as OpenLogi / Solaar):
/// 1. Root feature (index 0x00) `getFeature(0x1B04)` → index of REPROG_CONTROLS_V4.
/// 2. `setCidReporting(cid:divert: true)` for each wheel-button CID on that feature.
/// 3. The device then sends `divertedButtonsEvent` reports listing pressed CIDs.
///
/// Diversion is volatile: it is lost whenever the mouse reconnects to its receiver (wake from
/// deep sleep, power cycle). Receivers only report reconnects once their wireless notification
/// flag is set, so that flag is turned on while this controller runs and diversion is re-sent
/// on every reconnect and after the Mac wakes.
@MainActor
final class LogitechHIDPPController {
    var onSmartShiftPressed: (() -> Void)?

    private static let logitechVendorID = 0x046D
    private static let reprogControlsFeatureID: UInt16 = 0x1B04
    /// Buttons near the wheel: 0x00C4 = SmartShift (MX Master / Anywhere),
    /// 0x00FD = DPI / mode-shift button on other Logitech mice.
    private static let smartShiftCIDs: Set<UInt16> = [0x00C4, 0x00FD]
    private static let longReportID: UInt8 = 0x11
    private static let shortReportID: UInt8 = 0x10
    private static let longReportLength = 20
    private static let shortReportLength = 7
    private static let softwareID: UInt8 = 0x0A
    /// 0xFF = directly connected (Bluetooth), 1...6 = paired receiver slots.
    private static let candidateDeviceIndices: [UInt8] = [0xFF, 1, 2, 3, 4, 5, 6]
    private static let receiverUsagePage = 0xFF00
    private static let receiverIndex: UInt8 = 0xFF
    /// HID++ 1.0 receiver register access.
    private static let setRegisterSubID: UInt8 = 0x80
    private static let getRegisterSubID: UInt8 = 0x81
    private static let notificationFlagsRegister: UInt8 = 0x00
    /// Bit 8 of the notification flags (bit 0 of the middle byte): report device (dis)connections.
    private static let wirelessNotificationBit: UInt8 = 0x01
    private static let deviceConnectionSubID: UInt8 = 0x41
    private static let linkNotEstablishedBit: UInt8 = 0x40

    private struct DivertedTarget: Hashable {
        let device: IOHIDDevice
        let deviceIndex: UInt8
        let featureIndex: UInt8
    }

    private var manager: IOHIDManager?
    private var targets: Set<DivertedTarget> = []
    private var isSmartShiftDown = false
    /// Receivers whose notification flags were changed, with the original flags to restore.
    private var originalNotificationFlags: [IOHIDDevice: [UInt8]] = [:]
    private var wakeObserver: NSObjectProtocol?

    func start() {
        guard manager == nil else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [0xFF00, 0xFF43].map {
            [
                kIOHIDVendorIDKey: Self.logitechVendorID,
                kIOHIDPrimaryUsagePageKey: $0
            ]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let controller = Unmanaged<LogitechHIDPPController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { controller.deviceConnected(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let controller = Unmanaged<LogitechHIDPPController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { controller.deviceRemoved(device) }
        }, context)
        IOHIDManagerRegisterInputReportCallback(manager, { context, _, sender, _, _, report, length in
            guard let context, let sender else { return }
            let controller = Unmanaged<LogitechHIDPPController>.fromOpaque(context).takeUnretainedValue()
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            MainActor.assumeIsolated { controller.handleReport(bytes, from: device) }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reprobeAllDevices() }
        }
    }

    func stop() {
        guard let manager else { return }
        for target in targets {
            for cid in Self.smartShiftCIDs {
                setCidReporting(cid: cid, divert: false, target: target)
            }
        }
        targets.removeAll()
        for (device, flags) in originalNotificationFlags {
            writeNotificationFlags(flags, to: device)
        }
        originalNotificationFlags.removeAll()
        isSmartShiftDown = false
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    // MARK: - Device lifecycle

    private func deviceConnected(_ device: IOHIDDevice) {
        enableConnectionNotifications(on: device)
        probe(device: device)
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        targets = targets.filter { $0.device != device }
        originalNotificationFlags[device] = nil
    }

    private func reprobeAllDevices() {
        guard let manager, let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        for device in devices {
            deviceConnected(device)
        }
    }

    /// Asks a receiver for its notification flags; the reply turns on connection notifications.
    private func enableConnectionNotifications(on device: IOHIDDevice) {
        let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int
        guard usagePage == Self.receiverUsagePage else { return }
        sendShort(to: device, subID: Self.getRegisterSubID, parameters: [Self.notificationFlagsRegister])
    }

    private func writeNotificationFlags(_ flags: [UInt8], to device: IOHIDDevice) {
        sendShort(to: device, subID: Self.setRegisterSubID, parameters: [Self.notificationFlagsRegister] + flags)
    }

    private func probe(device: IOHIDDevice, indices: [UInt8] = candidateDeviceIndices) {
        let featureID = Self.reprogControlsFeatureID
        for deviceIndex in indices {
            send(
                to: device,
                deviceIndex: deviceIndex,
                featureIndex: 0x00,
                function: 0x00,
                parameters: [UInt8(featureID >> 8), UInt8(featureID & 0xFF)]
            )
        }
    }

    // MARK: - Reports

    private func handleReport(_ report: [UInt8], from device: IOHIDDevice) {
        guard report.count >= 4 else { return }

        // Receiver notification flags read back: turn on connection notifications if needed.
        if report[0] == Self.shortReportID, report.count >= 7, report[1] == Self.receiverIndex,
           report[2] == Self.getRegisterSubID, report[3] == Self.notificationFlagsRegister {
            let flags = Array(report[4..<7])
            guard flags[1] & Self.wirelessNotificationBit == 0 else { return }
            if originalNotificationFlags[device] == nil {
                originalNotificationFlags[device] = flags
            }
            var enabled = flags
            enabled[1] |= Self.wirelessNotificationBit
            writeNotificationFlags(enabled, to: device)
            return
        }

        // Receiver notification: a paired device connected or disconnected; diversion was reset.
        if report[0] == Self.shortReportID, report.count >= 5, report[2] == Self.deviceConnectionSubID {
            let deviceIndex = report[1]
            targets = targets.filter { !($0.device == device && $0.deviceIndex == deviceIndex) }
            if report[4] & Self.linkNotEstablishedBit == 0 {
                probe(device: device, indices: [deviceIndex])
            }
            return
        }

        guard report[0] == Self.longReportID || report[0] == Self.shortReportID else { return }
        let deviceIndex = report[1]
        let featureIndex = report[2]
        let function = report[3] >> 4
        let softwareID = report[3] & 0x0F

        // Root getFeature reply carrying the REPROG_CONTROLS_V4 index.
        if featureIndex == 0x00, function == 0x00, softwareID == Self.softwareID, report.count >= 5 {
            let reprogIndex = report[4]
            guard reprogIndex != 0 else { return }
            let target = DivertedTarget(device: device, deviceIndex: deviceIndex, featureIndex: reprogIndex)
            // Always re-send: the device may have dropped diversion without a reconnect report.
            targets.insert(target)
            for cid in Self.smartShiftCIDs {
                setCidReporting(cid: cid, divert: true, target: target)
            }
            return
        }

        // divertedButtonsEvent: up to four currently pressed CIDs.
        guard softwareID == 0, function == 0x00,
              targets.contains(where: { $0.device == device && $0.deviceIndex == deviceIndex && $0.featureIndex == featureIndex })
        else { return }

        var pressed: Set<UInt16> = []
        var offset = 4
        while offset + 1 < report.count {
            let cid = UInt16(report[offset]) << 8 | UInt16(report[offset + 1])
            if cid != 0 { pressed.insert(cid) }
            offset += 2
        }

        let isDown = !pressed.isDisjoint(with: Self.smartShiftCIDs)
        if isDown && !isSmartShiftDown {
            onSmartShiftPressed?()
        }
        isSmartShiftDown = isDown
    }

    private func setCidReporting(cid: UInt16, divert: Bool, target: DivertedTarget) {
        // Flags: bit0 = divert, bit1 = divert-valid.
        let flags: UInt8 = divert ? 0x03 : 0x02
        send(
            to: target.device,
            deviceIndex: target.deviceIndex,
            featureIndex: target.featureIndex,
            function: 0x03,
            parameters: [UInt8(cid >> 8), UInt8(cid & 0xFF), flags, 0x00, 0x00]
        )
    }

    private func send(
        to device: IOHIDDevice,
        deviceIndex: UInt8,
        featureIndex: UInt8,
        function: UInt8,
        parameters: [UInt8]
    ) {
        var report = [UInt8](repeating: 0, count: Self.longReportLength)
        report[0] = Self.longReportID
        report[1] = deviceIndex
        report[2] = featureIndex
        report[3] = (function << 4) | Self.softwareID
        for (offset, byte) in parameters.prefix(Self.longReportLength - 4).enumerated() {
            report[4 + offset] = byte
        }
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(Self.longReportID), report, report.count)
    }

    /// HID++ 1.0 short report addressed to the receiver itself.
    private func sendShort(to device: IOHIDDevice, subID: UInt8, parameters: [UInt8]) {
        var report = [UInt8](repeating: 0, count: Self.shortReportLength)
        report[0] = Self.shortReportID
        report[1] = Self.receiverIndex
        report[2] = subID
        for (offset, byte) in parameters.prefix(Self.shortReportLength - 3).enumerated() {
            report[3 + offset] = byte
        }
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(Self.shortReportID), report, report.count)
    }
}
