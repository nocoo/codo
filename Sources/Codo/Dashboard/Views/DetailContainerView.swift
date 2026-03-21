import SwiftUI

/// Switches between Dashboard, Settings, and Logs based on sidebar selection.
/// Supports Cmd+1/2/3 keyboard shortcuts for quick navigation.
struct DetailContainerView: View {
    @Environment(DashboardStore.self) private var store

    var body: some View {
        ZStack {
            switch store.selectedNav {
            case .dashboard:
                DashboardView()
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
            // Hidden buttons for Cmd+1/2/3 keyboard shortcuts
            keyboardShortcutButtons
        }
    }

    @ViewBuilder
    private var keyboardShortcutButtons: some View {
        Button("") { store.selectedNav = .dashboard }
            .keyboardShortcut("1", modifiers: .command)
            .hidden()
        Button("") { store.selectedNav = .settings }
            .keyboardShortcut("2", modifiers: .command)
            .hidden()
        Button("") { store.selectedNav = .logs }
            .keyboardShortcut("3", modifiers: .command)
            .hidden()
    }
}
