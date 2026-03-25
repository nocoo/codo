import SwiftUI

/// Navigation items for the dashboard sidebar.
enum NavigationItem: String, CaseIterable, Identifiable {
    case dashboard
    case history
    case settings
    case logs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard: "Dashboard"
        case .history: "History"
        case .settings: "Settings"
        case .logs: "Logs"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "gauge.open.with.lines.needle.33percent"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        case .logs: "doc.text"
        }
    }
}
