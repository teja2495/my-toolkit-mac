import Foundation

struct SystemHealthSnapshot: Equatable {
    var cpuUsage: Double
    var memoryUsage: Double
    var memoryPressure: Double
    var diskUsage: Double
    var batteryLevel: Double?
    var batteryIsCharging: Bool?
    var swapUsed: UInt64
    var swapTotal: UInt64
    var capturedAt: Date

    var needsAttention: Bool {
        cpuUsage >= 85
            || memoryPressure >= 80
            || diskUsage >= 90
            || batteryNeedsAttention
    }

    private var batteryNeedsAttention: Bool {
        guard let batteryLevel else { return false }
        return batteryLevel <= 20 && batteryIsCharging != true
    }

    static let empty = SystemHealthSnapshot(
        cpuUsage: 0,
        memoryUsage: 0,
        memoryPressure: 0,
        diskUsage: 0,
        batteryLevel: nil,
        batteryIsCharging: nil,
        swapUsed: 0,
        swapTotal: 0,
        capturedAt: .distantPast
    )
}

enum SystemHealthStatus {
    case good
    case attention
}

struct SystemHealthFormatter {
    static func percentage(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func swap(_ used: UInt64, total: UInt64) -> String {
        guard total > 0 else { return "0 KB" }
        return "\(bytes(used)) / \(bytes(total))"
    }
}
