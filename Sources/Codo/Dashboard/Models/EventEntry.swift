import Foundation

/// A single event entry displayed in the LiveEventStream.
struct EventEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let hookType: String
    let projectName: String?
    let summary: String
    let action: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        hookType: String,
        projectName: String? = nil,
        summary: String,
        action: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.hookType = hookType
        self.projectName = projectName
        self.summary = summary
        self.action = action
    }
}
