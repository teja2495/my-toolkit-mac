import AppKit
import SwiftUI

struct SystemHealthPopoverView: View {
    @ObservedObject var model: SystemHealthModel
    private static let green = Color(red: 0.22, green: 0.90, blue: 0.54)
    private static let amber = Color(red: 0.95, green: 0.67, blue: 0.25)
    private static let subtleRed = Color(red: 0.88, green: 0.35, blue: 0.35)
    private static let track = Color.primary.opacity(0.10)

    private var snapshot: SystemHealthSnapshot {
        model.snapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Health")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 18) {
                ringMetric(title: "CPU", value: snapshot.cpuUsage, tone: toneForCPU(snapshot.cpuUsage))
                ringMetric(title: "Memory", value: snapshot.memoryUsage, tone: toneForMemory(snapshot.memoryUsage))
                ringMetric(title: "Disk", value: snapshot.diskUsage, tone: toneForDisk(snapshot.diskUsage))
                ringMetric(
                    title: "Battery",
                    value: snapshot.batteryLevel ?? 0,
                    tone: toneForBattery(snapshot.batteryLevel),
                    isAvailable: snapshot.batteryLevel != nil,
                    isCharging: snapshot.batteryIsCharging == true
                )
            }

            if snapshot.batteryIsCharging == true {
                chargingCard
            }

            VStack(spacing: 10) {
                metricBarRow(
                    "Swap usage",
                    value: SystemHealthFormatter.swap(snapshot.swapUsed, total: snapshot.swapTotal),
                    progress: swapProgress,
                    tone: toneForSwap(swapProgress * 100)
                )

                processSection(
                    title: "Top CPU",
                    columnLabel: "CPU",
                    processes: snapshot.topCPUProcesses,
                    value: { SystemHealthFormatter.percentage($0.cpuUsage) },
                    tone: { toneForProcessCPU($0.cpuUsage) }
                )

                Divider()
                    .padding(.vertical, 2)

                processSection(
                    title: "Top Memory",
                    columnLabel: "Memory",
                    processes: snapshot.topMemoryProcesses,
                    value: { SystemHealthFormatter.processMemory($0.memoryBytes) },
                    tone: { toneForProcessMemory($0.memoryUsage) }
                )
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    quitAllRegularApps()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle")
                        Text("Quit All Apps")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)

                Button {
                    NSWorkspace.shared.launchApplication("Activity Monitor")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.dots.needle.50percent")
                        Text("Open Activity Monitor")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(width: 430)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var swapProgress: Double {
        guard snapshot.swapTotal > 0 else { return 0 }
        return Double(snapshot.swapUsed) / Double(snapshot.swapTotal)
    }

    private var chargingCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.green)
            Text("Charging")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let watts = snapshot.batteryChargingWatts {
                Text("\(Int(watts)) W")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Self.green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Self.green.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Self.green.opacity(0.20), lineWidth: 1)
        )
    }

    private func metricBarRow(_ title: String, value: String, progress: Double, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
            }

            GeometryReader { proxy in
                let clamped = min(max(progress, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Self.track)
                    Capsule()
                        .fill(tone)
                        .frame(width: max(4, proxy.size.width * clamped))
                }
            }
            .frame(height: 8)
        }
    }

    private func metricRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
        .frame(height: 28)
    }

    private func processSection(
        title: String,
        columnLabel: String,
        processes: [SystemHealthProcess],
        value: @escaping (SystemHealthProcess) -> String,
        tone: @escaping (SystemHealthProcess) -> Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(columnLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            if processes.isEmpty {
                Text("No process data")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(height: 24)
            } else {
                VStack(spacing: 3) {
                    ForEach(processes) { process in
                        processRow(process, value: value(process), tone: tone(process))
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func processRow(_ process: SystemHealthProcess, value: String, tone: Color) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tone)
                .frame(width: 3, height: 20)

            Text(process.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(tone)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tone.opacity(0.13))
                )

            Button(role: .destructive) {
                quitProcess(process.processIdentifier)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Quit \(process.name)")
        }
        .frame(height: 28)
    }

    private func ringMetric(title: String, value: Double, tone: Color, isAvailable: Bool = true, isCharging: Bool = false) -> some View {
        let clamped = min(max(value, 0), 100)
        return VStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(Self.track, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: clamped / 100)
                    .stroke(tone, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Text(isAvailable ? SystemHealthFormatter.percentage(clamped) : "--")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.9))
            }
            .frame(width: 80, height: 80)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.78))
        }
    }

    private func toneForCPU(_ value: Double) -> Color {
        if value > 90 { return Self.subtleRed }
        if value >= 85 { return Self.amber }
        return Self.green
    }

    private func toneForMemory(_ value: Double) -> Color {
        switch SystemHealthSnapshot.levelForMemory(value) {
        case .good:
            return Self.green
        case .attention:
            return Self.amber
        case .critical:
            return Self.subtleRed
        }
    }

    private func toneForDisk(_ value: Double) -> Color {
        if value > 95 { return Self.subtleRed }
        if value >= 90 { return Self.amber }
        return Self.green
    }

    private func toneForBattery(_ value: Double?) -> Color {
        guard let value else { return Self.green }
        if value < 15 { return Self.subtleRed }
        if value < 25 { return Self.amber }
        return Self.green
    }

    private func toneForSwap(_ value: Double) -> Color {
        if value >= 90 { return Self.subtleRed }
        if value >= 75 { return Self.amber }
        return Self.green
    }

    private func toneForProcessCPU(_ value: Double) -> Color {
        if value > 50 { return Self.subtleRed }
        if value >= 20 { return Self.amber }
        return Self.green
    }

    private func toneForProcessMemory(_ value: Double) -> Color {
        if value > 10 { return Self.subtleRed }
        if value >= 5 { return Self.amber }
        return Self.green
    }

    private func quitAllRegularApps() {
        let currentBundleIdentifier = Bundle.main.bundleIdentifier
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular &&
                !app.isTerminated &&
                app.processIdentifier != currentProcessIdentifier &&
                app.bundleIdentifier != currentBundleIdentifier
            }
            .forEach { $0.terminate() }
    }

    private func quitProcess(_ processIdentifier: Int32) {
        if let app = NSRunningApplication(processIdentifier: pid_t(processIdentifier)) {
            app.terminate()
            return
        }

        kill(pid_t(processIdentifier), SIGTERM)
    }
}
