import CodoCore
import SwiftUI

/// Browsable history of events and guardian decisions from SQLite.
struct HistoryView: View {
    @Environment(DashboardStore.self) private var store
    @State private var events: [EventRecord] = []
    @State private var decisions: [DecisionRecord] = []
    @State private var selectedTab: HistoryTab = .events
    @State private var selectedProject: String?
    @State private var pageSize = 50
    @State private var hasMore = true

    private enum HistoryTab: String, CaseIterable, Identifiable {
        case events = "Events"
        case decisions = "Decisions"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar: tab + project filter
            HStack {
                Picker("View", selection: $selectedTab) {
                    ForEach(HistoryTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)

                Spacer()

                projectPicker
            }
            .padding()

            Divider()

            // Content
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    switch selectedTab {
                    case .events:
                        eventsContent
                    case .decisions:
                        decisionsContent
                    }
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadData() }
        .onChange(of: selectedTab) { _, _ in loadData() }
        .onChange(of: selectedProject) { _, _ in loadData() }
        .onChange(of: store.selectedProjectCwd) { _, newValue in
            selectedProject = newValue
        }
    }

    // MARK: - Project Picker

    private var projectPicker: some View {
        Picker("Project", selection: $selectedProject) {
            Text("All Projects").tag(String?.none)
            ForEach(store.projects) { project in
                Text(project.name).tag(Optional(project.id))
            }
        }
        .frame(maxWidth: 200)
    }

    // MARK: - Events Content

    @ViewBuilder
    private var eventsContent: some View {
        if events.isEmpty {
            emptyState("No events found")
        } else {
            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                eventRow(event)
            }
            if hasMore {
                loadMoreButton
            }
        }
    }

    private func eventRow(_ event: EventRecord) -> some View {
        HStack(spacing: 8) {
            Text(event.timestamp, style: .date)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .trailing)

            Text(event.timestamp, style: .time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .trailing)

            if let hookType = event.hookType {
                hookBadge(hookType)
            } else {
                typeBadge(event.type)
            }

            if let name = event.projectName {
                Text(name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text(event.summary)
                .font(.callout)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Decisions Content

    @ViewBuilder
    private var decisionsContent: some View {
        if decisions.isEmpty {
            emptyState("No decisions found")
        } else {
            ForEach(Array(decisions.enumerated()), id: \.offset) { _, decision in
                decisionRow(decision)
            }
            if hasMore {
                loadMoreButton
            }
        }
    }

    private func decisionRow(_ decision: DecisionRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(decision.timestamp, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 60, alignment: .trailing)

                actionBadge(decision.action)

                if let tier = decision.tier {
                    Text(tier)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.purple.opacity(0.15))
                        .clipShape(Capsule())
                }

                if let title = decision.title {
                    Text(title)
                        .font(.callout)
                        .lineLimit(1)
                }

                Spacer()

                if let latency = decision.latencyMs {
                    Text("\(latency)ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // Detail row: tokens + model
            HStack(spacing: 12) {
                if let model = decision.model {
                    Label(model, systemImage: "cpu")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let prompt = decision.promptTokens,
                   let completion = decision.completionTokens {
                    Label("\(prompt)+\(completion) tokens", systemImage: "number")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let reason = decision.reason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 68)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Shared Components

    private func hookBadge(_ hookType: String) -> some View {
        Text(hookType)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(hookColor(hookType).opacity(0.2))
            .foregroundStyle(hookColor(hookType))
            .clipShape(Capsule())
    }

    private func typeBadge(_ type: String) -> some View {
        Text(type)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.gray.opacity(0.2))
            .foregroundStyle(.gray)
            .clipShape(Capsule())
    }

    private func actionBadge(_ action: String) -> some View {
        Text(action)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(action == "send" ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
            .foregroundStyle(action == "send" ? .green : .orange)
            .clipShape(Capsule())
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)
            Text(message)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }

    private var loadMoreButton: some View {
        Button("Load More") {
            pageSize += 50
            loadData()
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
    }

    private func hookColor(_ hookType: String) -> Color {
        switch hookType {
        case "session-start": .green
        case "session-end": .red
        case "stop": .blue
        case "post-tool-use": .orange
        case "notification": .purple
        default: .gray
        }
    }

    // MARK: - Data Loading

    private func loadData() {
        guard let eventStore = store.eventStore else { return }

        switch selectedTab {
        case .events:
            let results = eventStore.queryEvents(
                project: selectedProject,
                limit: pageSize
            )
            events = results
            hasMore = results.count >= pageSize
        case .decisions:
            let results = eventStore.queryDecisions(
                project: selectedProject,
                limit: pageSize
            )
            decisions = results
            hasMore = results.count >= pageSize
        }
    }
}
