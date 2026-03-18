import AppKit
import CodoCore
import os
import ServiceManagement
import UserNotifications

private let logger = Logger(subsystem: "ai.hexly.codo.01", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var socketServer: SocketServer?
    private var notificationService: NotificationService?

    private let socketDir = "\(NSHomeDirectory())/.codo"
    private var socketPath: String { "\(socketDir)/codo.sock" }

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        setupStatusItem()
        setupMenu()
        startDaemon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        socketServer?.stop()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        if let button = statusItem.button {
            // Load template image from bundle Resources
            if let img = Bundle.main.image(forResource: "menubar") {
                img.isTemplate = true
                button.image = img
            } else {
                // Fallback to SF Symbol if bundle image not found
                button.image = NSImage(
                    systemSymbolName: "bell",
                    accessibilityDescription: "Codo"
                )
                button.image?.isTemplate = true
            }
        }
    }

    // MARK: - Menu

    private func setupMenu() {
        let menu = NSMenu()

        let versionItem = NSMenuItem(
            title: "Codo v\(CodoInfo.version)",
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(NSMenuItem.separator())

        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLoginItem(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = isLoginItemEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Codo",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Login Item

    private var isLoginItemEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    sender.state = .off
                } else {
                    try SMAppService.mainApp.register()
                    sender.state = .on
                }
            } catch {
                fputs("login item error: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    // MARK: - Daemon

    private func startDaemon() {
        #if canImport(UserNotifications)
        let provider = SystemNotificationProvider()
        notificationService = NotificationService(provider: provider)
        #endif

        // Request notification permission on startup
        if let service = notificationService {
            Task {
                _ = await service.requestPermission()
            }
        }

        socketServer = SocketServer(socketPath: socketPath) { [weak self] message in
            guard let self, let service = self.notificationService else {
                return .error("notifications unavailable (no app bundle)")
            }

            // Bridge sync handler to async NotificationService.
            // Use Task.detached to avoid inheriting MainActor context,
            // which would deadlock with the semaphore.
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result: CodoResponse = .error("timeout")

            Task.detached {
                result = await service.post(message: message)
                semaphore.signal()
            }

            semaphore.wait()
            return result
        }

        do {
            try socketServer?.start()
            fputs("Codo daemon listening on \(socketPath)\n", stderr)
        } catch {
            fputs("Failed to start socket server: \(error)\n", stderr)
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Always show banner + sound even when app is "foreground" (menubar apps count).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        logger.notice("willPresent called for: \(notification.request.content.title)")
        completionHandler([.banner, .sound, .list])
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
