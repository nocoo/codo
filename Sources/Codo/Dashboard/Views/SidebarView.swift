import SwiftUI

/// Sidebar navigation for the dashboard.
struct SidebarView: View {
    @Environment(DashboardStore.self) private var store
    @State private var selectedNav: NavigationItem = .dashboard
    @State private var selectedProject: ProjectInfo?

    var body: some View {
        List {
            Section("NAVIGATION") {
                ForEach(NavigationItem.allCases) { item in
                    Button {
                        selectedNav = item
                    } label: {
                        Label(item.label, systemImage: item.systemImage)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(
                        selectedNav == item
                            ? Color.accentColor.opacity(0.2)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .animation(.easeInOut(duration: 0.15), value: selectedNav)
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
        .environment(\.selectedNavigation, $selectedNav)
    }
}

// MARK: - Environment Key for Navigation Selection

private struct SelectedNavigationKey: EnvironmentKey {
    static let defaultValue: Binding<NavigationItem> = .constant(.dashboard)
}

extension EnvironmentValues {
    var selectedNavigation: Binding<NavigationItem> {
        get { self[SelectedNavigationKey.self] }
        set { self[SelectedNavigationKey.self] = newValue }
    }
}
