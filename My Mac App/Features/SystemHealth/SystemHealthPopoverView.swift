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
            HStack(spacing: 10) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)

                Text("System Health")
                    .font(.system(size: 15, weight: .semibold))

                Spacer(minLength: 0)
            }

            HStack(spacing: 18) {
                ringMetric(title: "CPU", value: snapshot.cpuUsage, tone: toneForCPU(snapshot.cpuUsage))
                ringMetric(title: "Memory", value: snapshot.memoryUsage, tone: toneForMemory(snapshot.memoryUsage))
                ringMetric(title: "Disk", value: snapshot.diskUsage, tone: toneForDisk(snapshot.diskUsage))
                ringMetric(
                    title: "Battery",
                    value: snapshot.batteryLevel ?? 0,
                    tone: toneForBattery(snapshot.batteryLevel),
                    isAvailable: snapshot.batteryLevel != nil
                )
            }

            VStack(spacing: 10) {
                metricBarRow(
                    "Swap usage",
                    value: SystemHealthFormatter.swap(snapshot.swapUsed, total: snapshot.swapTotal),
                    progress: swapProgress,
                    tone: toneForSwap(swapProgress * 100)
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
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .frame(width: 430)
    }

    private var dotColor: Color {
        switch snapshot.menuBarStatus {
        case .good:
            return Self.green
        case .attention:
            return Self.amber
        case .critical:
            return Self.subtleRed
        }
    }

    private var swapProgress: Double {
        guard snapshot.swapTotal > 0 else { return 0 }
        return Double(snapshot.swapUsed) / Double(snapshot.swapTotal)
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

    private func ringMetric(title: String, value: Double, tone: Color, isAvailable: Bool = true) -> some View {
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
}
