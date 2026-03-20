import SwiftUI

/// Main dashboard view with status cards, sessions, and live event stream.
struct DashboardView: View {
    @Environment(DashboardStore.self) private var store
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Top row: status cards
                HStack(spacing: 16) {
                    GuardianStatusCard()
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)
                    StatsCard()
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)
                }

                // Active sessions
                ActiveSessionsList()
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 8)

                // Live event stream
                LiveEventStream()
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 8)
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35).delay(0.05)) {
                appeared = true
            }
        }
    }
}
