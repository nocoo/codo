import SwiftUI

/// Lists active Claude Code sessions.
struct ActiveSessionsList: View {
    @Environment(DashboardStore.self) private var store

    var body: some View {
        CardView(title: "Active Sessions") {
            if store.filteredSessions.isEmpty {
                emptyState
            } else {
                VStack(spacing: 4) {
                    ForEach(store.filteredSessions) { session in
                        sessionRow(session)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)
            Text("No active sessions")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 12)
    }

    private func sessionRow(_ session: SessionInfo) -> some View {
        HStack(spacing: 8) {
            PulsingDot()
            Text(session.projectName)
                .font(.system(.body, weight: .medium))
            if let model = session.model {
                Text(model)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
            Text(session.startTime, style: .relative)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Pulsing Green Dot

private struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 6, height: 6)
            .shadow(color: .green.opacity(isPulsing ? 0.6 : 0), radius: 4)
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .animation(
                .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}
