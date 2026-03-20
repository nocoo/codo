import SwiftUI

/// Main dashboard view with status cards, sessions, and live event stream.
struct DashboardView: View {
    @Environment(DashboardStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Top row: status cards
                HStack(spacing: 16) {
                    GuardianStatusCard()
                    StatsCard()
                }

                // Active sessions
                ActiveSessionsList()

                // Live event stream
                LiveEventStream()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
