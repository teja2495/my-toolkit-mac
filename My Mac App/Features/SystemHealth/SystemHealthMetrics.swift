import Foundation

struct SystemHealthSnapshot: Equatable {
    var cpuUsage: Double
    var memoryUsage: Double
    var diskUsage: Double
    var batteryLevel: Double?
    var batteryIsCharging: Bool?
    var batteryChargingWatts: Double?
    var swapUsed: UInt64
    var swapTotal: UInt64
    var topCPUProcesses: [SystemHealthProcess]
    var topMemoryProcesses: [SystemHealthProcess]
    var capturedAt: Date

    var menuBarStatus: SystemHealthStatus {
        let diskLevel = levelForDisk(diskUsage)
        let batteryLevel = levelForBattery(self.batteryLevel)
        return [diskLevel, batteryLevel].max() ?? .good
    }

    var memoryStatus: SystemHealthStatus {
        Self.levelForMemory(memoryUsage)
    }

    var needsAttention: Bool {
        menuBarStatus != .good
    }

    private func levelForDisk(_ value: Double) -> SystemHealthStatus {
        if value > 95 { return .critical }
        if value >= 90 { return .attention }
        return .good
    }

    private func levelForBattery(_ value: Double?) -> SystemHealthStatus {
        guard let value else { return .good }
        if value < 15 { return .critical }
        if value < 25 { return .attention }
        return .good
    }

    static func levelForMemory(_ value: Double) -> SystemHealthStatus {
        if value > 90 { return .critical }
        if value >= 85 { return .attention }
        return .good
    }

    static let empty = SystemHealthSnapshot(
        cpuUsage: 0,
        memoryUsage: 0,
        diskUsage: 0,
        batteryLevel: nil,
        batteryIsCharging: nil,
        batteryChargingWatts: nil,
        swapUsed: 0,
        swapTotal: 0,
        topCPUProcesses: [],
        topMemoryProcesses: [],
        capturedAt: .distantPast
    )
}

struct SystemHealthProcess: Equatable, Identifiable {
    var id: Int32 { processIdentifier }
    var processIdentifier: Int32
    var name: String
    var cpuUsage: Double
    var memoryUsage: Double
    var memoryBytes: UInt64
}

enum SystemHealthStatus: Int, Comparable {
    case good
    case attention
    case critical

    static func < (lhs: SystemHealthStatus, rhs: SystemHealthStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct SystemHealthFormatter {
    static func percentage(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func processMemory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }

    static func bytes(_ value: UInt64) -> String {
        let gb = Double(value) / 1_000_000_000
        return String(format: "%.2f GB", gb)
    }

    static func swap(_ used: UInt64, total: UInt64) -> String {
        guard total > 0 else { return "0.00 GB / 0.00 GB" }
        return "\(bytes(used)) / \(bytes(total))"
    }
}
