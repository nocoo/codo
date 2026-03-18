import Foundation

/// Request message from CLI to daemon.
public struct CodoMessage: Codable, Sendable {
    public let title: String
    public let body: String?
    public let sound: String?

    public init(title: String, body: String?, sound: String?) {
        self.title = title
        self.body = body
        self.sound = sound
    }

    /// Returns the effective sound setting, defaulting to "default" when nil.
    public var effectiveSound: String {
        sound ?? "default"
    }

    /// Validates the message. Returns an error string if invalid, nil if valid.
    public func validate() -> String? {
        if title.trimmingCharacters(in: .whitespaces).isEmpty {
            return "title is required"
        }
        return nil
    }
}
