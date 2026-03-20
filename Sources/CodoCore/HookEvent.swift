import Foundation

/// Lightweight decode of hook event JSON from Claude Code hooks.
/// Uses explicit CodingKeys because payload keys use `_hook` prefix
/// and `snake_case` which `.convertFromSnakeCase` cannot handle correctly.
public struct HookEvent: Decodable, Sendable {
    public let hook: String
    public let sessionId: String?
    public let cwd: String?
    public let model: String?
    public let hookEventName: String?

    private enum CodingKeys: String, CodingKey {
        case hook = "_hook"
        case sessionId = "session_id"
        case cwd
        case model
        case hookEventName = "hook_event_name"
    }
}
