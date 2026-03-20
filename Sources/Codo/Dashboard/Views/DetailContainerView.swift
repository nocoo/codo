import SwiftUI

/// Switches between Dashboard, Settings, and Logs based on sidebar selection.
struct DetailContainerView: View {
    @Environment(\.selectedNavigation) private var selectedNav

    var body: some View {
        switch selectedNav.wrappedValue {
        case .dashboard:
            DashboardView()
        case .settings:
            SettingsView()
        case .logs:
            LogsView()
        }
    }
}
