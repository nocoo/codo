import AppKit
import CodoCore
import os
import ServiceManagement
import UserNotifications

private let logger = Logger(subsystem: "ai.hexly.codo.04", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var socketServer: SocketServer?
    private var notificationService: NotificationService?

    // Guardian
    private var guardian: GuardianProcess?
    private let guardianSettings = GuardianSettings()
    private var settingsWindow: SettingsWindowController?
    private var guardianToggleItem: NSMenuItem?

    private let socketDir = "\(NSHomeDirectory())/.codo"
    private var socketPath: String { "\(socketDir)/codo.sock" }

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMenu()
        UNUserNotificationCenter.current().delegate = self
        EditMenuSetup.install()
        startDaemon()
        spawnGuardianIfNeeded()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidSave),
            name: SettingsWindowController.settingsDidSave,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        guardian?.stop()
        socketServer?.stop()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        if let button = statusItem.button {
            if let img = Bundle.main.image(forResource: "menubar") {
                img.isTemplate = true
                button.image = img
            } else {
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

        let toggleItem = NSMenuItem(
            title: "AI Guardian",
            action: #selector(toggleGuardian(_:)),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.state = guardianSettings.guardianEnabled ? .on : .off
        menu.addItem(toggleItem)
        guardianToggleItem = toggleItem

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
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

    // MARK: - Guardian Lifecycle

    @objc private func toggleGuardian(_ sender: NSMenuItem) {
        let newState = !guardianSettings.guardianEnabled
        guardianSettings.guardianEnabled = newState
        sender.state = newState ? .on : .off

        if newState {
            spawnGuardianIfNeeded()
        } else {
            guardian?.stop()
            guardian = nil
        }
    }

    @objc private func settingsDidSave() {
        // Sync menu toggle state
        guardianToggleItem?.state = guardianSettings.guardianEnabled ? .on : .off

        // Stop existing Guardian and restart with new config
        guardian?.stop()
        guardian = nil
        spawnGuardianIfNeeded()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.showWindow()
    }

    private func spawnGuardianIfNeeded() {
        let enabled = guardianSettings.guardianEnabled
        let apiKey = KeychainService.readAPIKey()
        let guardianPath = GuardianPathResolver.resolve()
        let bunPath = GuardianProcess.resolveBunPath()

        let hasKey = apiKey != nil && !(apiKey ?? "").isEmpty
        fputs("spawnGuardian: en=\(enabled) key=\(hasKey) "
            + "guard=\(guardianPath ?? "nil") bun=\(bunPath ?? "nil") "
            + "svc=\(self.notificationService != nil)\n", stderr)

        guard enabled,
              let apiKey, !apiKey.isEmpty,
              let guardianPath,
              let bunPath,
              let service = notificationService else { return }

        let proc = GuardianProcess(
            notificationService: service,
            guardianPath: guardianPath,
            bunPath: bunPath
        )
        proc.onDisabled = { [weak self] in
            self?.guardianToggleItem?.state = .off
            self?.guardianSettings.guardianEnabled = false
            logger.warning("Guardian disabled after repeated crashes")
        }
        do {
            try proc.start(config: guardianSettings.toEnvironment(apiKey: apiKey))
            guardian = proc
            logger.info("Guardian process started")
        } catch {
            logger.error("Failed to start Guardian: \(error)")
        }
    }

    // MARK: - Daemon

    private func startDaemon() {
        let provider = BannerProvider()
        notificationService = NotificationService(provider: provider)

        if let service = notificationService {
            Task { _ = await service.requestPermission() }
        }

        socketServer = SocketServer(socketPath: socketPath, asyncRawHandler: { [weak self] data in
            guard let self else { return .error("shutting down") }

            let routed: RoutedMessage
            do {
                routed = try MessageRouter.route(data)
            } catch {
                return .error("invalid json")
            }

            switch routed {
            case .notification(let message):
                guard let service = self.notificationService else {
                    return .error("notifications unavailable (no app bundle)")
                }
                return await service.post(message: message)
            case .hookEvent(_, let rawJSON):
                self.dispatchHookEvent(rawJSON: rawJSON)
                return .ok
            }
        })

        do {
            try socketServer?.start()
            fputs("Codo daemon listening on \(socketPath)\n", stderr)
        } catch {
            fputs("Failed to start socket server: \(error)\n", stderr)
            NSApplication.shared.terminate(nil)
        }
    }

    private func dispatchHookEvent(rawJSON: Data) {
        if let guardian, guardian.isAlive {
            Task.detached { await guardian.send(line: rawJSON) }
        } else {
            Task.detached { [weak self] in
                await self?.deliverFallback(rawJSON: rawJSON)
            }
        }
    }

    private func deliverFallback(rawJSON: Data) async {
        guard let service = notificationService,
              let message = FallbackNotification.build(from: rawJSON) else {
            return
        }
        _ = await service.post(message: message)
    }

    // MARK: - UNUserNotificationCenterDelegate

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
