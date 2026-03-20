import Foundation

/// Tracks an active Claude Code session.
struct SessionInfo: Identifiable {
    let id: String  // session_id from hook event
    let cwd: String
    let projectName: String
    let model: String?
    let startTime: Date

    init(
        id: String,
        cwd: String,
        model: String? = nil,
        startTime: Date = Date()
    ) {
        self.id = id
        self.cwd = cwd
        self.projectName = URL(fileURLWithPath: cwd).lastPathComponent
        self.model = model
        self.startTime = startTime
    }
}
