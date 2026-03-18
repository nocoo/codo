import Foundation
import Testing

@testable import CodoCore

// MARK: - Mock Provider

final class MockNotificationProvider: NotificationProvider, @unchecked Sendable {
    var mockIsAvailable = true
    var mockPermissionGranted = true
    var mockPostError: String?
    var postedMessages: [CodoMessage] = []

    var isAvailable: Bool { mockIsAvailable }

    func requestPermission() async -> Bool {
        mockPermissionGranted
    }

    func post(message: CodoMessage) async -> String? {
        postedMessages.append(message)
        return mockPostError
    }
}

// MARK: - Tests

@Suite("NotificationService")
struct NotificationServiceTests {
    @Test func postSuccess() async {
        let mock = MockNotificationProvider()
        let service = NotificationService(provider: mock)

        let msg = CodoMessage(title: "Hello", body: "World", sound: nil)
        let response = await service.post(message: msg)
        #expect(response.isOk == true)
        #expect(mock.postedMessages.count == 1)
        #expect(mock.postedMessages[0].title == "Hello")
        #expect(mock.postedMessages[0].body == "World")
        #expect(mock.postedMessages[0].effectiveSound == "default")
    }

    @Test func postWithExplicitSound() async {
        let mock = MockNotificationProvider()
        let service = NotificationService(provider: mock)

        let msg = CodoMessage(title: "T", body: nil, sound: "none")
        let response = await service.post(message: msg)
        #expect(response.isOk == true)
        #expect(mock.postedMessages[0].effectiveSound == "none")
    }

    @Test func unavailableProvider() async {
        let mock = MockNotificationProvider()
        mock.mockIsAvailable = false
        let service = NotificationService(provider: mock)

        let msg = CodoMessage(title: "T", body: nil, sound: nil)
        let response = await service.post(message: msg)
        #expect(response.isOk == false)
        #expect(response.errorMessage == "notifications unavailable (no app bundle)")
        #expect(mock.postedMessages.isEmpty)
    }

    @Test func postError() async {
        let mock = MockNotificationProvider()
        mock.mockPostError = "notification failed: something"
        let service = NotificationService(provider: mock)

        let msg = CodoMessage(title: "T", body: nil, sound: nil)
        let response = await service.post(message: msg)
        #expect(response.isOk == false)
        #expect(response.errorMessage == "notification failed: something")
    }

    @Test func postWithSubtitleAndThreadId() async {
        let mock = MockNotificationProvider()
        let service = NotificationService(provider: mock)

        let msg = CodoMessage(title: "T", body: "B", subtitle: "✅ Success", threadId: "build")
        let response = await service.post(message: msg)
        #expect(response.isOk == true)
        #expect(mock.postedMessages.count == 1)
        #expect(mock.postedMessages[0].subtitle == "✅ Success")
        #expect(mock.postedMessages[0].threadId == "build")
    }

    @Test func requestPermissionGranted() async {
        let mock = MockNotificationProvider()
        mock.mockPermissionGranted = true
        let service = NotificationService(provider: mock)

        let granted = await service.requestPermission()
        #expect(granted == true)
    }

    @Test func requestPermissionDenied() async {
        let mock = MockNotificationProvider()
        mock.mockPermissionGranted = false
        let service = NotificationService(provider: mock)

        let granted = await service.requestPermission()
        #expect(granted == false)
    }

    @Test func requestPermissionUnavailable() async {
        let mock = MockNotificationProvider()
        mock.mockIsAvailable = false
        let service = NotificationService(provider: mock)

        let granted = await service.requestPermission()
        #expect(granted == false)
    }
}
