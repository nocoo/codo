import AppKit
import CommonCrypto
import CodoCore
import Foundation
import Observation

/// Single source of truth for all dashboard data.
/// Must be accessed from the main thread (@MainActor).
@MainActor
@Observable
final class DashboardStore {
    // MARK: - Navigation

    var selectedNav: NavigationItem = .dashboard

    // MARK: - Status

    var guardianAlive = false
    var socketAlive = false
    var guardianStartTime: Date?

    var guardianUptime: TimeInterval {
        guard guardianAlive, let start = guardianStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    // MARK: - Stats

    var notificationsSent = 0
    var notificationsSuppressed = 0

    // MARK: - Events (ring buffer, newest first)

    private(set) var events: [EventEntry] = []
    private static let maxEvents = 200

    // MARK: - Sessions

    private(set) var activeSessions: [SessionInfo] = []

    // MARK: - Projects

    var projects: [ProjectInfo] = [] {
        didSet { persistProjects() }
    }

    // MARK: - Project Filter

    /// Selected project cwd for filtering. nil = show all.
    var selectedProjectCwd: String?

    /// Events filtered by selected project (or all if nil).
    var filteredEvents: [EventEntry] {
        guard let cwd = selectedProjectCwd else { return events }
        return events.filter { $0.projectCwd == cwd }
    }

    /// Sessions filtered by selected project (or all if nil).
    var filteredSessions: [SessionInfo] {
        guard let cwd = selectedProjectCwd else { return activeSessions }
        return activeSessions.filter { $0.cwd == cwd }
    }

    // MARK: - Persistence

    let eventStore: EventStore?

    // MARK: - Polling

    private var pollTimer: Timer?

    private var guardianProvider: (() -> GuardianProvider?)?
    private weak var socketServer: SocketServer?

    // MARK: - Init

    init(eventStore: EventStore? = nil) {
        self.eventStore = eventStore
        loadProjects()
        migrateProjectsToSQLite()
        loadTodayStats()
    }

    // MARK: - Public Methods

    /// Start polling Guardian and SocketServer status every 2 seconds.
    func startPolling(
        guardianProvider: @escaping () -> GuardianProvider?,
        socketServer: SocketServer?
    ) {
        self.guardianProvider = guardianProvider
        self.socketServer = socketServer

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        // Run immediately once
        poll()
    }

    /// Process an incoming hook event from AppDelegate.
    func ingestHookEvent(_ event: HookEvent) {
        // Canonicalize cwd for consistent project identification
        let canonicalCwd = event.cwd.map { canonicalizeCwd($0) }

        var projectName = canonicalCwd.map {
            URL(fileURLWithPath: $0).lastPathComponent
        }

        // Track sessions
        if let sessionId = event.sessionId {
            switch event.hook {
            case "session-start":
                if let cwd = canonicalCwd {
                    let session = SessionInfo(
                        id: sessionId,
                        cwd: cwd,
                        model: event.model
                    )
                    activeSessions.removeAll { $0.id == sessionId }
                    activeSessions.insert(session, at: 0)
                    discoverProject(cwd: cwd)
                }

            case "session-end":
                // session-end may lack cwd — look up from active sessions
                if let existing = activeSessions.first(where: { $0.id == sessionId }) {
                    updateProjectLastSeen(cwd: existing.cwd)
                    // Backfill project name when event lacks cwd
                    if projectName == nil {
                        projectName = existing.projectName
                    }
                }
                activeSessions.removeAll { $0.id == sessionId }

            default:
                // For other hooks, update project lastSeen if cwd available
                if let cwd = canonicalCwd {
                    discoverProject(cwd: cwd)
                }
            }
        }

        // Build event summary
        let summary = buildSummary(for: event)

        // Resolve projectCwd: prefer canonicalCwd, fall back to active session lookup
        let resolvedCwd = canonicalCwd ?? {
            if let sessionId = event.sessionId,
               let existing = activeSessions.first(where: { $0.id == sessionId }) {
                return existing.cwd
            }
            return nil
        }()

        let entry = EventEntry(
            hookType: event.hook,
            projectCwd: resolvedCwd,
            projectName: projectName,
            summary: summary
        )
        events.insert(entry, at: 0)
        if events.count > Self.maxEvents {
            events.removeLast(events.count - Self.maxEvents)
        }

        // Persist to SQLite (non-blocking — EventStore is thread-safe)
        eventStore?.insertEvent(EventRecord(
            type: "hook",
            hookType: event.hook,
            sessionId: event.sessionId,
            projectCwd: resolvedCwd,
            projectName: projectName,
            summary: summary
        ))
    }

    /// Process a GuardianAction from the stdout callback.
    func ingestGuardianAction(_ action: GuardianAction) {
        switch action.action {
        case "send":
            notificationsSent += 1
        case "suppress":
            notificationsSuppressed += 1
        default:
            break
        }

        // Persist decision to SQLite
        eventStore?.insertDecision(DecisionRecord(
            sessionId: action.meta?.sessionId,
            projectCwd: action.meta?.cwd,
            hookType: action.meta?.hookType,
            tier: action.meta?.tier,
            action: action.action,
            title: action.notification?.title,
            reason: action.reason,
            model: action.meta?.model,
            promptTokens: action.meta?.promptTokens,
            completionTokens: action.meta?.completionTokens,
            latencyMs: action.meta?.latencyMs
        ))
    }

    /// Process a direct notification (no _hook field) for dashboard tracking.
    func ingestDirectNotification(_ message: CodoMessage) {
        let cwd = message.cwd.map { canonicalizeCwd($0) }
        let projectName = cwd.map {
            URL(fileURLWithPath: $0).lastPathComponent
        }

        // Discover project if cwd is present
        if let cwd {
            discoverProject(cwd: cwd)
        }

        // Add to event ring buffer
        let entry = EventEntry(
            hookType: "notification",
            projectCwd: cwd,
            projectName: projectName,
            summary: message.title
        )
        events.insert(entry, at: 0)
        if events.count > Self.maxEvents {
            events.removeLast(events.count - Self.maxEvents)
        }

        // Persist to SQLite
        eventStore?.insertEvent(EventRecord(
            type: "notification",
            projectCwd: cwd,
            projectName: projectName,
            summary: message.title
        ))
    }

    // MARK: - Private

    private func poll() {
        let wasAlive = guardianAlive
        guardianAlive = guardianProvider?()?.isAlive ?? false
        socketAlive = socketServer?.isListening ?? false

        // Track guardian start time
        if guardianAlive && !wasAlive {
            guardianStartTime = Date()
        } else if !guardianAlive && wasAlive {
            guardianStartTime = nil
        }
    }

    /// Load today's notification stats from SQLite so counters survive restart.
    private func loadTodayStats() {
        guard let eventStore else { return }
        let stats = eventStore.todayStats()
        notificationsSent = stats.sent
        notificationsSuppressed = stats.suppressed
    }

    private func discoverProject(cwd: String) {
        let canonical = canonicalizeCwd(cwd)
        if let idx = projects.firstIndex(where: { $0.id == canonical }) {
            projects[idx].lastSeen = Date()
        } else {
            projects.append(ProjectInfo(cwd: canonical))
        }
    }

    private func updateProjectLastSeen(cwd: String) {
        let canonical = canonicalizeCwd(cwd)
        if let idx = projects.firstIndex(where: { $0.id == canonical }) {
            projects[idx].lastSeen = Date()
        }
    }

    private func buildSummary(for event: HookEvent) -> String {
        switch event.hook {
        case "session-start":
            let model = event.model ?? "unknown"
            return "Session started (\(model))"
        case "session-end":
            return "Session ended"
        case "stop":
            return event.hookEventName ?? "Task stopped"
        case "post-tool-use":
            return event.hookEventName ?? "Tool used"
        case "notification":
            return "Notification"
        default:
            return event.hookEventName ?? event.hook
        }
    }
}

// MARK: - Project Persistence & Migration

extension DashboardStore {
    static let projectsKey = "CodoDashboardProjects"

    func persistProjects() {
        // Write to SQLite if available
        if let eventStore {
            for project in projects {
                eventStore.upsertProject(ProjectRecord(
                    cwd: project.id,
                    name: project.name,
                    customLogoPath: project.customLogoPath,
                    lastSeen: project.lastSeen
                ))
            }
        }
    }

    func loadProjects() {
        // Prefer SQLite if available and has data
        if let eventStore {
            let records = eventStore.loadProjects()
            if !records.isEmpty {
                projects = records.map {
                    ProjectInfo(
                        cwd: $0.cwd,
                        customLogoPath: $0.customLogoPath,
                        lastSeen: $0.lastSeen
                    )
                }
                return
            }
        }

        // Fall back to UserDefaults (pre-migration or no EventStore)
        guard let data = UserDefaults.standard.data(forKey: Self.projectsKey),
              let saved = try? JSONDecoder().decode([ProjectInfo].self, from: data)
        else { return }
        projects = saved
    }

    /// Migrate projects from UserDefaults to SQLite, then clear the key.
    func migrateProjectsToSQLite() {
        guard let eventStore else { return }

        // Only migrate if UserDefaults data exists
        guard let data = UserDefaults.standard.data(forKey: Self.projectsKey),
              let saved = try? JSONDecoder().decode([ProjectInfo].self, from: data),
              !saved.isEmpty
        else { return }

        // Check if SQLite already has projects (no need to migrate again)
        if eventStore.projectCount() > 0 {
            // Already migrated — just clean up UserDefaults
            UserDefaults.standard.removeObject(forKey: Self.projectsKey)
            return
        }

        // Backup to JSON before migration
        let backupPath = "\(NSHomeDirectory())/.codo/projects-backup.json"
        try? data.write(to: URL(fileURLWithPath: backupPath))

        // Migrate each project with canonicalized cwd
        for project in saved {
            eventStore.upsertProject(ProjectRecord(
                cwd: project.id,
                name: project.name,
                customLogoPath: project.customLogoPath,
                lastSeen: project.lastSeen
            ))
        }

        // Verify row counts match
        let migratedCount = eventStore.projectCount()
        if migratedCount >= saved.count {
            UserDefaults.standard.removeObject(forKey: Self.projectsKey)
            // Reload from SQLite to get canonicalized cwds
            let records = eventStore.loadProjects()
            projects = records.map {
                ProjectInfo(
                    cwd: $0.cwd,
                    customLogoPath: $0.customLogoPath,
                    lastSeen: $0.lastSeen
                )
            }
        }
        // If verification fails, keep UserDefaults as fallback
    }
}
