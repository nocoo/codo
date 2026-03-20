import CodoCore
import Foundation
import Observation

/// Single source of truth for all dashboard data.
/// Must be accessed from the main thread (@MainActor).
@MainActor
@Observable
final class DashboardStore {
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

    // MARK: - Polling

    private var pollTimer: Timer?

    private var guardianProvider: (() -> GuardianProvider?)?
    private weak var socketServer: SocketServer?

    // MARK: - Init

    init() {
        loadProjects()
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
        let projectName = event.cwd.map {
            URL(fileURLWithPath: $0).lastPathComponent
        }

        // Track sessions
        if let sessionId = event.sessionId {
            switch event.hook {
            case "session-start":
                if let cwd = event.cwd {
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
                }
                activeSessions.removeAll { $0.id == sessionId }

            default:
                // For other hooks, update project lastSeen if cwd available
                if let cwd = event.cwd {
                    discoverProject(cwd: cwd)
                }
            }
        }

        // Build event summary
        let summary = buildSummary(for: event)

        let entry = EventEntry(
            hookType: event.hook,
            projectName: projectName,
            summary: summary
        )
        events.insert(entry, at: 0)
        if events.count > Self.maxEvents {
            events.removeLast(events.count - Self.maxEvents)
        }
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

    private func discoverProject(cwd: String) {
        if let idx = projects.firstIndex(where: { $0.id == cwd }) {
            projects[idx].lastSeen = Date()
        } else {
            projects.append(ProjectInfo(cwd: cwd))
        }
    }

    private func updateProjectLastSeen(cwd: String) {
        if let idx = projects.firstIndex(where: { $0.id == cwd }) {
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

    // MARK: - Persistence

    private static let projectsKey = "CodoDashboardProjects"

    private func persistProjects() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        UserDefaults.standard.set(data, forKey: Self.projectsKey)
    }

    private func loadProjects() {
        guard let data = UserDefaults.standard.data(forKey: Self.projectsKey),
              let saved = try? JSONDecoder().decode([ProjectInfo].self, from: data)
        else { return }
        projects = saved
    }
}
