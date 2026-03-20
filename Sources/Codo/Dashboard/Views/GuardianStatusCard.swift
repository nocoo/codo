import SwiftUI

/// Shows Guardian and Socket connection status.
struct GuardianStatusCard: View {
    @Environment(DashboardStore.self) private var store

    var body: some View {
        CardView(title: "Status") {
            VStack(alignment: .leading, spacing: 6) {
                statusRow(
                    label: "Guardian",
                    alive: store.guardianAlive,
                    detail: store.guardianAlive ? uptimeText : nil
                )
                statusRow(
                    label: "Socket",
                    alive: store.socketAlive
                )
            }
        }
    }

    private func statusRow(
        label: String,
        alive: Bool,
        detail: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(alive ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .animation(.easeInOut(duration: 0.3), value: alive)
            Text(label)
                .font(.system(.body, weight: .medium))
            Text(alive ? "Running" : "Stopped")
                .foregroundStyle(.secondary)
                .font(.callout)
                .contentTransition(.numericText())
            if let detail {
                Spacer()
                Text(detail)
                    .foregroundStyle(.tertiary)
                    .font(.callout.monospacedDigit())
            }
        }
    }

    private var uptimeText: String {
        let total = Int(store.guardianUptime)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
