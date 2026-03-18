#if canImport(UserNotifications)
import UserNotifications

/// Real notification provider using UNUserNotificationCenter.
/// Only works when running inside a .app bundle with a valid bundleIdentifier.
public final class SystemNotificationProvider: NotificationProvider, @unchecked Sendable {
    public var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    public init() {}

    public func requestPermission() async -> Bool {
        guard isAvailable else { return false }
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    public func post(title: String, body: String?, sound: String) async -> String? {
        guard isAvailable else {
            return "notifications unavailable (no app bundle)"
        }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized else {
            return "notification permission denied"
        }

        let content = UNMutableNotificationContent()
        content.title = title
        if let body {
            content.body = body
        }
        if sound == "default" {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            return nil
        } catch {
            return "notification failed: \(error.localizedDescription)"
        }
    }
}
#endif
