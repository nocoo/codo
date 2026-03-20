import SwiftUI

/// Lists active Claude Code sessions.
struct ActiveSessionsList: View {
    @Environment(DashboardStore.self) private var store

    var body: some View {
        CardView(title: "Active Sessions") {
            if store.activeSessions.isEmpty {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 4) {
                    ForEach(store.activeSessions) { session in
                        sessionRow(session)
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: SessionInfo) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
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
