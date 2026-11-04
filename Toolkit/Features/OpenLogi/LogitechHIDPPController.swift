import Foundation
import IOKit.hid

/// Minimal HID++ 2.0 client that diverts the Logitech button near the wheel (SmartShift / DPI)
/// so its presses are delivered to the app instead of toggling the wheel ratchet.
///
/// Flow (same as OpenLogi / Solaar):
/// 1. Root feature (index 0x00) `getFeature(0x1B04)` → index of REPROG_CONTROLS_V4.
/// 2. `setCidReporting(cid:divert: true)` for each wheel-button CID on that feature.
/// 3. The device then sends `divertedButtonsEvent` reports listing pressed CIDs.
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
    private static let softwareID: UInt8 = 0x0A
    /// 0xFF = directly connected (Bluetooth), 1...6 = paired receiver slots.
    private static let candidateDeviceIndices: [UInt8] = [0xFF, 1, 2, 3, 4, 5, 6]

    private struct DivertedTarget: Hashable {
        let device: IOHIDDevice
        let deviceIndex: UInt8
        let featureIndex: UInt8
    }

    private var manager: IOHIDManager?
    private var targets: Set<DivertedTarget> = []
    private var isSmartShiftDown = false

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
    }

    func stop() {
        guard let manager else { return }
        for target in targets {
            for cid in Self.smartShiftCIDs {
                setCidReporting(cid: cid, divert: false, target: target)
            }
        }
        targets.removeAll()
        isSmartShiftDown = false
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    // MARK: - Device lifecycle

    private func deviceConnected(_ device: IOHIDDevice) {
        probe(device: device)
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        targets = targets.filter { $0.device != device }
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

        // Receiver notification: a paired device (re)connected, so diversion was reset.
        if report[0] == Self.shortReportID, report[2] == 0x41 {
            let deviceIndex = report[1]
            targets = targets.filter { !($0.device == device && $0.deviceIndex == deviceIndex) }
            probe(device: device, indices: [deviceIndex])
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
            guard !targets.contains(target) else { return }
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
}
