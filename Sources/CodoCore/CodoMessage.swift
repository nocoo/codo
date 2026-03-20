import Foundation

/// Request message from CLI to daemon.
public struct CodoMessage: Codable, Sendable {
    public let title: String
    public let body: String?
    public let subtitle: String?
    public let source: String?      // project name (basename of cwd)
    public let sound: String?
    public let threadId: String?

    public init(
        title: String,
        body: String? = nil,
        subtitle: String? = nil,
        source: String? = nil,
        sound: String? = nil,
        threadId: String? = nil
    ) {
        self.title = title
        self.body = body
        self.subtitle = subtitle
        self.source = source
        self.sound = sound
        self.threadId = threadId
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
