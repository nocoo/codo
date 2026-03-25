import SwiftUI

/// Switches between Dashboard, History, Settings, and Logs based on sidebar selection.
/// Supports Cmd+1/2/3/4 keyboard shortcuts for quick navigation.
struct DetailContainerView: View {
    @Environment(DashboardStore.self) private var store

    var body: some View {
        ZStack {
            switch store.selectedNav {
            case .dashboard:
                DashboardView()
                    .transition(.opacity)
            case .history:
                HistoryView()
                    .transition(.opacity)
            case .settings:
                SettingsView()
                    .transition(.opacity)
            case .logs:
                LogsView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: store.selectedNav)
        .background {
            keyboardShortcutButtons
        }
    }

    @ViewBuilder
    private var keyboardShortcutButtons: some View {
        Button("") { store.selectedNav = .dashboard }
            .keyboardShortcut("1", modifiers: .command)
            .hidden()
        Button("") { store.selectedNav = .history }
            .keyboardShortcut("2", modifiers: .command)
            .hidden()
        Button("") { store.selectedNav = .settings }
            .keyboardShortcut("3", modifiers: .command)
            .hidden()
        Button("") { store.selectedNav = .logs }
            .keyboardShortcut("4", modifiers: .command)
            .hidden()
    }
}
