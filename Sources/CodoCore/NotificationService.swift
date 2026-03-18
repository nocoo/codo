import Foundation

/// Protocol for notification posting, enabling testability.
public protocol NotificationProvider: Sendable {
    /// Whether the notification system is available.
    var isAvailable: Bool { get }

    /// Request notification permission. Returns true if granted.
    func requestPermission() async -> Bool

    /// Post a notification from a CodoMessage. Returns nil on success, error string on failure.
    func post(message: CodoMessage) async -> String?
}

/// Notification service that bridges CodoMessage to the notification provider.
public final class NotificationService: Sendable {
    private let provider: NotificationProvider

    public init(provider: NotificationProvider) {
        self.provider = provider
    }

    /// Request notification permission. Call on daemon startup.
    public func requestPermission() async -> Bool {
        guard provider.isAvailable else { return false }
        return await provider.requestPermission()
    }

    /// Post a notification for a CodoMessage. Returns a CodoResponse.
    public func post(message: CodoMessage) async -> CodoResponse {
        guard provider.isAvailable else {
            return .error("notifications unavailable (no app bundle)")
        }

        if let error = await provider.post(message: message) {
            return .error(error)
        }

        return .ok
    }
}
