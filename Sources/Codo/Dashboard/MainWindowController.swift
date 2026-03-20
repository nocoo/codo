import AppKit
import SwiftUI

/// Main dashboard window controller.
/// NSWindow + NSSplitViewController shell with SwiftUI content panels.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let dashboardStore: DashboardStore
    private let settingsViewModel: SettingsViewModel

    init(dashboardStore: DashboardStore, settingsViewModel: SettingsViewModel) {
        self.dashboardStore = dashboardStore
        self.settingsViewModel = settingsViewModel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 800, height: 500)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("CodoDashboard")
        window.identifier = NSUserInterfaceItemIdentifier("CodoDashboard")

        super.init(window: window)
        window.delegate = self

        setupContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

    private func setupContent() {
        let splitVC = NSSplitViewController()

        // Sidebar
        let sidebarVC = NSViewController()
        let sidebarView = SidebarView()
            .environmentObject(settingsViewModel)
            .environment(dashboardStore)
        sidebarVC.view = NSHostingView(rootView: sidebarView)
        let sidebarItem = NSSplitViewItem(
            sidebarWithViewController: sidebarVC
        )
        sidebarItem.minimumThickness = 180
        sidebarItem.canCollapse = false
        splitVC.addSplitViewItem(sidebarItem)

        // Detail
        let detailVC = NSViewController()
        let detailView = DetailContainerView()
            .environmentObject(settingsViewModel)
            .environment(dashboardStore)
        detailVC.view = NSHostingView(rootView: detailView)
        let detailItem = NSSplitViewItem(
            contentListWithViewController: detailVC
        )
        splitVC.addSplitViewItem(detailItem)

        window?.contentViewController = splitVC
    }

    // MARK: - Show / Hide

    func showDashboard() {
        NSApp.setActivationPolicy(.regular)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
