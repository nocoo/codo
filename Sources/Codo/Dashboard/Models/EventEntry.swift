import Foundation

/// A single event entry displayed in the LiveEventStream.
struct EventEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let hookType: String
    let projectCwd: String?     // canonical cwd for reliable project filtering
    let projectName: String?    // display name (basename of cwd)
    let summary: String
    let action: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        hookType: String,
        projectCwd: String? = nil,
        projectName: String? = nil,
        summary: String,
        action: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.hookType = hookType
        self.projectCwd = projectCwd
        self.projectName = projectName
        self.summary = summary
        self.action = action
    }
}
