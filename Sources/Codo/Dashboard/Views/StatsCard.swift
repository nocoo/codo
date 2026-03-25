import CodoCore
import SwiftUI

/// Shows notification statistics with today's aggregated data from SQLite.
struct StatsCard: View {
    @Environment(DashboardStore.self) private var store
    @State private var todayStats: TodayStatsSummary = .empty

    var body: some View {
        CardView(title: "Statistics") {
            VStack(spacing: 12) {
                // Primary row: sent / suppressed / sessions
                HStack(spacing: 24) {
                    statColumn(value: store.notificationsSent, label: "Sent", color: .green)
                    statColumn(value: store.notificationsSuppressed, label: "Suppressed", color: .orange)
                    statColumn(value: store.filteredSessions.count, label: "Sessions", color: .blue)
                }

                Divider()

                // Secondary row: token usage from SQLite
                HStack(spacing: 24) {
                    statColumn(value: todayStats.promptTokens + todayStats.completionTokens,
                               label: "Tokens", color: .purple)
                    statColumn(value: todayStats.promptTokens, label: "Prompt", color: .secondary)
                    statColumn(value: todayStats.completionTokens, label: "Completion", color: .secondary)
                }
            }
        }
        .onAppear { refreshStats() }
        .onChange(of: store.notificationsSent) { _, _ in refreshStats() }
        .onChange(of: store.notificationsSuppressed) { _, _ in refreshStats() }
    }

    private func refreshStats() {
        guard let eventStore = store.eventStore else { return }
        todayStats = eventStore.todayStats()
    }

    private func statColumn(value: Int, label: String, color: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(.title2, weight: .bold).monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.3), value: value)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
