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
    private var mainWindow: MainWindowController?
    private var guardianToggleItem: NSMenuItem?

    // Dashboard — initialized lazily on main thread in applicationDidFinishLaunching
    private var dashboardStore: DashboardStore!
    private var eventStore: EventStore?

    private let socketDir = "\(NSHomeDirectory())/.codo"
    private var socketPath: String { "\(socketDir)/codo.sock" }

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize SQLite event store for persistent dashboard data
        do {
            eventStore = try EventStore()
            // Auto-vacuum old data (>30 days) on startup
            eventStore?.vacuum(keepDays: 30)
        } catch {
            logger.error("Failed to open EventStore: \(error)")
            // Continue without persistence — DashboardStore accepts nil
        }

        dashboardStore = DashboardStore(eventStore: eventStore)
        setupStatusItem()
        setupMenu()
        UNUserNotificationCenter.current().delegate = self
        EditMenuSetup.install()
        startDaemon()

        // Clean up orphaned guardians from previous sessions (cold start only)
        if let guardianPath = GuardianPathResolver.resolve() {
            GuardianProcess.killOrphans(guardianPath: guardianPath)
        }

        spawnGuardianIfNeeded()

        dashboardStore.startPolling(
            guardianProvider: { [weak self] in self?.guardian },
            socketServer: socketServer
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidSave),
            name: SettingsViewModel.settingsDidSave,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        guardian?.stop()
        socketServer?.stop()
        eventStore?.close()
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

        let versionItem = NSMenuItem(title: "Codo v\(CodoInfo.version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(NSMenuItem.separator())

        let toggleItem = NSMenuItem(title: "AI Guardian", action: #selector(toggleGuardian(_:)), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = guardianSettings.guardianEnabled ? .on : .off
        menu.addItem(toggleItem)
        guardianToggleItem = toggleItem

        let settingsItem = NSMenuItem(title: "Dashboard...", action: #selector(openDashboard), keyEquivalent: "d")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLoginItemEnabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Codo", action: #selector(quitApp), keyEquivalent: "q")
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
        guardianToggleItem?.state = guardianSettings.guardianEnabled ? .on : .off
        spawnGuardianIfNeeded()
    }

    @objc private func openDashboard() {
        if mainWindow == nil {
            mainWindow = MainWindowController(
                dashboardStore: dashboardStore,
                settingsViewModel: SettingsViewModel()
            )
        }
        mainWindow?.showDashboard()
    }

    private func spawnGuardianIfNeeded() {
        // Stop any existing guardian before spawning a new one
        if let existing = guardian {
            existing.stop()
            guardian = nil
        }
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
        proc.onAction = { [weak self] action in
            Task { @MainActor in
                self?.dashboardStore.ingestGuardianAction(action)
            }
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
        notificationService = NotificationService(provider: BannerProvider())

        if let service = notificationService {
            Task { _ = await service.requestPermission() }
        }

        socketServer = SocketServer(
            socketPath: socketPath,
            asyncRawHandler: { [weak self] data in
                guard let self else { return .error("shutting down") }
                return await self.handleSocketMessage(data)
            }
        )

        do {
            try socketServer?.start()
            fputs("Codo daemon listening on \(socketPath)\n", stderr)
        } catch {
            fputs("Failed to start socket server: \(error)\n", stderr)
            NSApplication.shared.terminate(nil)
        }
    }

    private func handleSocketMessage(_ data: Data) async -> CodoResponse {
        let routed: RoutedMessage
        do {
            routed = try MessageRouter.route(data)
        } catch {
            return .error("invalid json")
        }

        switch routed {
        case .notification(let message):
            guard let service = notificationService else {
                return .error("notifications unavailable (no app bundle)")
            }
            Task { @MainActor in self.dashboardStore.ingestDirectNotification(message) }
            return await service.post(message: message)
        case .hookEvent(_, let rawJSON):
            dispatchHookEvent(rawJSON: rawJSON)
            return .ok
        }
    }

    private func dispatchHookEvent(rawJSON: Data) {
        if let event = try? JSONDecoder().decode(HookEvent.self, from: rawJSON) {
            Task { @MainActor [weak self] in
                self?.dashboardStore.ingestHookEvent(event)
            }
        }

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
