import SwiftUI

struct SystemHealthPopoverView: View {
    @ObservedObject var model: SystemHealthModel

    private var snapshot: SystemHealthSnapshot {
        model.snapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Circle()
                    .fill(snapshot.needsAttention ? Color.orange : Color.green)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text("System Health")
                        .font(.system(size: 15, weight: .semibold))
                    Text(snapshot.needsAttention ? "Action recommended" : "All checks look good")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            VStack(spacing: 0) {
                metricRow("CPU usage", value: SystemHealthFormatter.percentage(snapshot.cpuUsage))
                metricDivider()
                metricRow("Memory usage", value: SystemHealthFormatter.percentage(snapshot.memoryUsage))
                metricDivider()
                metricRow("Memory pressure", value: SystemHealthFormatter.percentage(snapshot.memoryPressure))
                metricDivider()
                metricRow("Disk usage", value: SystemHealthFormatter.percentage(snapshot.diskUsage))
                metricDivider()
                metricRow("Battery", value: batteryText)
                metricDivider()
                metricRow(
                    "Swap usage",
                    value: SystemHealthFormatter.swap(snapshot.swapUsed, total: snapshot.swapTotal)
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
        }
        .padding(18)
        .frame(width: 290)
    }

    private var batteryText: String {
        guard let batteryLevel = snapshot.batteryLevel else { return "Not available" }
        let suffix = snapshot.batteryIsCharging == true ? " charging" : ""
        return "\(SystemHealthFormatter.percentage(batteryLevel))\(suffix)"
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

    private func metricDivider() -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
    }
}
