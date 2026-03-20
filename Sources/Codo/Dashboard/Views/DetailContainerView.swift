import SwiftUI

/// Switches between Dashboard, Settings, and Logs based on sidebar selection.
/// Supports Cmd+1/2/3 keyboard shortcuts for quick navigation.
struct DetailContainerView: View {
    @Environment(\.selectedNavigation) private var selectedNav

    var body: some View {
        ZStack {
            switch selectedNav.wrappedValue {
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
        .animation(.easeInOut(duration: 0.15), value: selectedNav.wrappedValue)
        .background {
            // Hidden buttons for Cmd+1/2/3 keyboard shortcuts
            keyboardShortcuts
        }
    }

    @ViewBuilder
    private var keyboardShortcuts: some View {
        Button("") { selectedNav.wrappedValue = .dashboard }
            .keyboardShortcut("1", modifiers: .command)
            .hidden()
        Button("") { selectedNav.wrappedValue = .settings }
            .keyboardShortcut("2", modifiers: .command)
            .hidden()
        Button("") { selectedNav.wrappedValue = .logs }
            .keyboardShortcut("3", modifiers: .command)
            .hidden()
    }
}
