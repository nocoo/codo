import SwiftUI

/// Sidebar navigation for the dashboard.
struct SidebarView: View {
    @Environment(DashboardStore.self) private var store
    @State private var selectedProject: ProjectInfo?

    var body: some View {
        @Bindable var store = store
        List {
            Section("NAVIGATION") {
                ForEach(NavigationItem.allCases) { item in
                    Button {
                        store.selectedNav = item
                    } label: {
                        Label(item.label, systemImage: item.systemImage)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(
                        store.selectedNav == item
                            ? Color.accentColor.opacity(0.2)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .animation(
                        .easeInOut(duration: 0.15),
                        value: store.selectedNav
                    )
                }
            }

            if !store.projects.isEmpty {
                Section("PROJECTS") {
                    ForEach(store.projects) { project in
                        ProjectRow(project: project)
                            .onTapGesture {
                                selectedProject = project
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180, idealWidth: 220)
    }
}
