import Foundation

/// Result of routing a raw JSON message.
public enum RoutedMessage: Sendable {
    /// Standard notification — decoded into CodoMessage.
    case notification(CodoMessage)
    /// Hook event — raw JSON bytes forwarded to Guardian as-is.
    /// `hook` is the event type (e.g., "stop", "notification"), extracted for logging only.
    case hookEvent(hook: String, rawJSON: Data)
}

public enum MessageRouterError: Error {
    case invalidJSON
}

/// Routes raw JSON to either CodoMessage or hook event path.
/// Does NOT decode hook events — only peeks at `_hook` field.
public enum MessageRouter {
    public static func route(_ data: Data) throws -> RoutedMessage {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MessageRouterError.invalidJSON
        }

        if let hook = obj["_hook"] as? String {
            // Hook event: forward raw bytes, don't decode further
            return .hookEvent(hook: hook, rawJSON: data)
        } else {
            // Standard notification: decode as CodoMessage
            do {
                let message = try JSONDecoder().decode(CodoMessage.self, from: data)
                return .notification(message)
            } catch {
                throw MessageRouterError.invalidJSON
            }
        }
    }
}
