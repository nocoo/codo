import Foundation

// MARK: - Event Record

/// A structured event record stored in the SQLite `events` table.
public struct EventRecord: Codable, Sendable {
    public let timestamp: Date
    public let type: String          // "hook" | "notification" | "guardian_action"
    public let hookType: String?
    public let sessionId: String?
    public let projectCwd: String?   // canonical path, NULL for unattributed notifications
    public let projectName: String?
    public let summary: String
    public let rawJson: String?

    public init(
        timestamp: Date = Date(),
        type: String,
        hookType: String? = nil,
        sessionId: String? = nil,
        projectCwd: String? = nil,
        projectName: String? = nil,
        summary: String,
        rawJson: String? = nil
    ) {
        self.timestamp = timestamp
        self.type = type
        self.hookType = hookType
        self.sessionId = sessionId
        self.projectCwd = projectCwd
        self.projectName = projectName
        self.summary = summary
        self.rawJson = rawJson
    }
}

// MARK: - Decision Record

/// A structured Guardian decision record stored in the SQLite `guardian_decisions` table.
public struct DecisionRecord: Codable, Sendable {
    public let timestamp: Date
    public let sessionId: String?
    public let projectCwd: String?
    public let hookType: String?
    public let tier: String?
    public let action: String        // "send" | "suppress"
    public let title: String?
    public let reason: String?
    public let model: String?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let latencyMs: Int?

    public init(
        timestamp: Date = Date(),
        sessionId: String? = nil,
        projectCwd: String? = nil,
        hookType: String? = nil,
        tier: String? = nil,
        action: String,
        title: String? = nil,
        reason: String? = nil,
        model: String? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        latencyMs: Int? = nil
    ) {
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.projectCwd = projectCwd
        self.hookType = hookType
        self.tier = tier
        self.action = action
        self.title = title
        self.reason = reason
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.latencyMs = latencyMs
    }
}

// MARK: - Daily Stats Record

/// Aggregated daily statistics per project, stored in the SQLite `daily_stats` table.
public struct DailyStatsRecord: Codable, Sendable {
    public let date: String          // YYYY-MM-DD
    public let projectCwd: String    // canonical cwd or "__unattributed__"
    public let eventsCount: Int
    public let sentCount: Int
    public let suppressedCount: Int
    public let promptTokens: Int
    public let completionTokens: Int
    public let llmCalls: Int

    public init(
        date: String,
        projectCwd: String,
        eventsCount: Int = 0,
        sentCount: Int = 0,
        suppressedCount: Int = 0,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        llmCalls: Int = 0
    ) {
        self.date = date
        self.projectCwd = projectCwd
        self.eventsCount = eventsCount
        self.sentCount = sentCount
        self.suppressedCount = suppressedCount
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.llmCalls = llmCalls
    }

    /// Sentinel value for events without a project cwd.
    public static let unattributed = "__unattributed__"
}

// MARK: - Project Record

/// A project record stored in the SQLite `projects` table.
public struct ProjectRecord: Codable, Sendable {
    public let cwd: String           // canonical path
    public let name: String
    public let customLogoPath: String?
    public let lastSeen: Date

    public init(
        cwd: String,
        name: String,
        customLogoPath: String? = nil,
        lastSeen: Date = Date()
    ) {
        self.cwd = cwd
        self.name = name
        self.customLogoPath = customLogoPath
        self.lastSeen = lastSeen
    }
}
