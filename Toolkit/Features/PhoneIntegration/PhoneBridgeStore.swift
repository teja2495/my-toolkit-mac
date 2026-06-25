import Foundation

final class PhoneBridgeStore {
    private let trustedDevicesKey = "phoneIntegration.trustedDevices"
    private let deviceIdKey = "phoneIntegration.deviceId"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func deviceId() -> String {
        if let existing = defaults.string(forKey: deviceIdKey) {
            return existing
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: deviceIdKey)
        return id
    }

    func trustedDevices() -> [PhoneTrustedDevice] {
        guard let data = defaults.data(forKey: trustedDevicesKey),
              let decoded = try? JSONDecoder().decode([PhoneTrustedDevice].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func saveTrustedDevice(_ device: PhoneTrustedDevice) {
        let devices = trustedDevices()
            .filter { $0.id != device.id }
            .plus(device)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: trustedDevicesKey)
        }
    }

    func removeTrustedDevice(id: String) {
        let devices = trustedDevices().filter { $0.id != id }
        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: trustedDevicesKey)
        }
    }
}

private extension Array {
    func plus(_ element: Element) -> [Element] {
        self + [element]
    }
}
