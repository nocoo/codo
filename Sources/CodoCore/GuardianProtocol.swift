import Foundation

/// A notification action emitted by the Guardian on stdout.
public struct GuardianAction: Codable, Sendable {
    public let action: String  // "send" or "suppress"
    public let notification: CodoMessage?  // present when action == "send"
    public let reason: String?             // present when action == "suppress"

    public init(action: String, notification: CodoMessage? = nil, reason: String? = nil) {
        self.action = action
        self.notification = notification
        self.reason = reason
    }
}

/// Protocol for Guardian communication, enabling testability.
public protocol GuardianProvider: Sendable {
    var isAlive: Bool { get }

    /// Send raw JSON line to Guardian stdin. Fire-and-forget — does not wait for response.
    func send(line: Data) async

    /// Start the Guardian process. Pass config via environment variables.
    func start(config: [String: String]) throws

    /// Stop the Guardian process (SIGTERM).
    func stop()
}

/// Mock Guardian provider for testing. Records sent lines and simulates state.
public final class MockGuardianProvider: GuardianProvider, @unchecked Sendable {
    public private(set) var sentLines: [Data] = []
    public private(set) var started = false
    public private(set) var stopped = false
    public private(set) var startConfig: [String: String]?
    public var mockIsAlive = false

    public init() {}

    public var isAlive: Bool { mockIsAlive }

    public func send(line: Data) async {
        sentLines.append(line)
    }

    public func start(config: [String: String]) throws {
        started = true
        startConfig = config
        mockIsAlive = true
    }

    public func stop() {
        stopped = true
        mockIsAlive = false
    }
}
