import Darwin
import Foundation
import IOKit.ps

final class SystemHealthMonitor {
    private var previousCPUInfo: processor_info_array_t?
    private var previousCPUInfoCount: mach_msg_type_number_t = 0

    deinit {
        deallocatePreviousCPUInfo()
    }

    func snapshot() -> SystemHealthSnapshot {
        let memory = memoryMetrics()
        let swap = swapMetrics()
        let battery = batteryMetrics()

        return SystemHealthSnapshot(
            cpuUsage: cpuUsage(),
            memoryUsage: memory.usage,
            memoryPressure: memory.pressure,
            diskUsage: diskUsage(),
            batteryLevel: battery.level,
            batteryIsCharging: battery.isCharging,
            swapUsed: swap.used,
            swapTotal: swap.total,
            capturedAt: Date()
        )
    }

    private func cpuUsage() -> Double {
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        var processorCount: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &cpuInfo,
            &cpuInfoCount
        )

        guard result == KERN_SUCCESS, let cpuInfo else { return 0 }
        defer {
            previousCPUInfo = cpuInfo
            previousCPUInfoCount = cpuInfoCount
        }

        guard let previousCPUInfo else { return 0 }

        var totalUsage: Double = 0
        for processorIndex in 0..<Int(processorCount) {
            let offset = processorIndex * Int(CPU_STATE_MAX)
            let user = Double(cpuInfo[offset + Int(CPU_STATE_USER)] - previousCPUInfo[offset + Int(CPU_STATE_USER)])
            let system = Double(cpuInfo[offset + Int(CPU_STATE_SYSTEM)] - previousCPUInfo[offset + Int(CPU_STATE_SYSTEM)])
            let nice = Double(cpuInfo[offset + Int(CPU_STATE_NICE)] - previousCPUInfo[offset + Int(CPU_STATE_NICE)])
            let idle = Double(cpuInfo[offset + Int(CPU_STATE_IDLE)] - previousCPUInfo[offset + Int(CPU_STATE_IDLE)])
            let total = user + system + nice + idle

            guard total > 0 else { continue }
            totalUsage += (user + system + nice) / total
        }

        deallocatePreviousCPUInfo()

        guard processorCount > 0 else { return 0 }
        return min(100, max(0, (totalUsage / Double(processorCount)) * 100))
    }

    private func memoryMetrics() -> (usage: Double, pressure: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else { return (0, 0) }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let speculative = UInt64(stats.speculative_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let free = UInt64(stats.free_count) * pageSize
        let purgeable = UInt64(stats.purgeable_count) * pageSize
        let appUsed = active + wired + compressed
        let reclaimable = inactive + speculative + purgeable + free
        let total = appUsed + reclaimable

        guard total > 0 else { return (0, 0) }

        let usage = Double(appUsed) / Double(total) * 100
        let pressure = Double(active + wired + compressed) / Double(total) * 100
        return (min(100, max(0, usage)), min(100, max(0, pressure)))
    }

    private func diskUsage() -> Double {
        do {
            let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeTotalCapacityKey
            ])

            guard let total = values.volumeTotalCapacity, total > 0 else { return 0 }
            let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
            let used = max(0, Int64(total) - available)
            return min(100, max(0, Double(used) / Double(total) * 100))
        } catch {
            return 0
        }
    }

    private func batteryMetrics() -> (level: Double?, isCharging: Bool?) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]
        else {
            return (nil, nil)
        }

        let current = description[kIOPSCurrentCapacityKey] as? Double
        let maximum = description[kIOPSMaxCapacityKey] as? Double
        let state = description[kIOPSPowerSourceStateKey] as? String
        let isCharging = state == kIOPSACPowerValue || (description[kIOPSIsChargingKey] as? Bool) == true

        guard let current, let maximum, maximum > 0 else { return (nil, isCharging) }
        return (min(100, max(0, current / maximum * 100)), isCharging)
    }

    private func swapMetrics() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)

        guard result == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    private func deallocatePreviousCPUInfo() {
        if let previousCPUInfo {
            let byteCount = vm_size_t(previousCPUInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: previousCPUInfo), byteCount)
        }
        previousCPUInfo = nil
        previousCPUInfoCount = 0
    }
}
