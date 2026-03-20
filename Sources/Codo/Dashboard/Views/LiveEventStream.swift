import SwiftUI

/// Scrollable live event stream showing hook events in real time.
struct LiveEventStream: View {
    @Environment(DashboardStore.self) private var store

    var body: some View {
        CardView(title: "Event Stream") {
            if store.events.isEmpty {
                Text("Waiting for events...")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(store.events) { event in
                                eventRow(event)
                                    .id(event.id)
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                    .onChange(of: store.events.first?.id) { _, newId in
                        if let newId {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(newId, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
    }

    private func eventRow(_ event: EventEntry) -> some View {
        HStack(spacing: 8) {
            Text(event.timestamp, style: .time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .trailing)

            hookBadge(event.hookType)

            if let project = event.projectName {
                Text(project)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text(event.summary)
                .font(.callout)
                .lineLimit(1)

            if let action = event.action {
                Spacer()
                Text(action)
                    .font(.caption)
                    .foregroundStyle(action == "send" ? .green : .orange)
            }
        }
        .padding(.vertical, 2)
    }

    private func hookBadge(_ hookType: String) -> some View {
        Text(hookType)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor(for: hookType).opacity(0.2))
            .foregroundStyle(badgeColor(for: hookType))
            .clipShape(Capsule())
    }

    private func badgeColor(for hookType: String) -> Color {
        switch hookType {
        case "session-start": .green
        case "session-end": .red
        case "stop": .blue
        case "post-tool-use": .orange
        case "notification": .purple
        default: .gray
        }
    }
}
