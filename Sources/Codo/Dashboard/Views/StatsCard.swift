import SwiftUI

/// Shows notification statistics: sent, suppressed, active sessions.
struct StatsCard: View {
    @Environment(DashboardStore.self) private var store

    var body: some View {
        CardView(title: "Statistics") {
            HStack(spacing: 24) {
                statColumn(value: store.notificationsSent, label: "Sent")
                statColumn(value: store.notificationsSuppressed, label: "Suppressed")
                statColumn(value: store.activeSessions.count, label: "Sessions")
            }
        }
    }

    private func statColumn(value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(.title2, weight: .bold).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.3), value: value)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
