import SwiftUI

/// Sidebar navigation for the dashboard.
struct SidebarView: View {
    @Environment(DashboardStore.self) private var store

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
                    // "All" option to clear filter
                    Button {
                        store.selectedProjectCwd = nil
                    } label: {
                        Label("All Projects", systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(
                        store.selectedProjectCwd == nil
                            ? Color.accentColor.opacity(0.15) : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    ForEach(store.projects) { project in
                        ProjectRow(project: project)
                            .background(
                                store.selectedProjectCwd == project.id
                                    ? Color.accentColor.opacity(0.15) : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .onTapGesture {
                                store.selectedProjectCwd =
                                    store.selectedProjectCwd == project.id
                                    ? nil : project.id
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180, idealWidth: 220)
    }
}
