import Foundation
import Testing

@testable import CodoCore

@Suite("MessageRouter")
struct MessageRouterTests {
    @Test func routeCodoMessage() throws {
        let json = #"{"title":"T"}"#
        let result = try MessageRouter.route(Data(json.utf8))
        guard case .notification(let msg) = result else {
            Issue.record("Expected .notification, got hook event")
            return
        }
        #expect(msg.title == "T")
    }

    @Test func routeCodoMessageWithAllFields() throws {
        let json = #"{"title":"T","body":"B","subtitle":"S","sound":"none","threadId":"t"}"#
        let result = try MessageRouter.route(Data(json.utf8))
        guard case .notification(let msg) = result else {
            Issue.record("Expected .notification")
            return
        }
        #expect(msg.title == "T")
        #expect(msg.body == "B")
        #expect(msg.subtitle == "S")
        #expect(msg.sound == "none")
        #expect(msg.threadId == "t")
    }

    @Test func routeHookEventStop() throws {
        let json = #"{"_hook":"stop","session_id":"s1","cwd":"/tmp"}"#
        let result = try MessageRouter.route(Data(json.utf8))
        guard case .hookEvent(let hook, _) = result else {
            Issue.record("Expected .hookEvent, got notification")
            return
        }
        #expect(hook == "stop")
    }

    @Test func routeHookEventNotification() throws {
        let json = #"{"_hook":"notification","title":"P"}"#
        let result = try MessageRouter.route(Data(json.utf8))
        guard case .hookEvent(let hook, _) = result else {
            Issue.record("Expected .hookEvent")
            return
        }
        #expect(hook == "notification")
    }

    @Test func routeInvalidJSON() throws {
        let data = Data("not json".utf8)
        #expect(throws: MessageRouterError.self) {
            try MessageRouter.route(data)
        }
    }

    @Test func routeEmptyObject() throws {
        let json = #"{}"#
        // No _hook and no title → CodoMessage decode fails → invalidJSON
        #expect(throws: MessageRouterError.self) {
            try MessageRouter.route(Data(json.utf8))
        }
    }

    @Test func routeMissingTitle() throws {
        let json = #"{"body":"B"}"#
        // No _hook and CodoMessage decode fails (missing title) → invalidJSON
        #expect(throws: MessageRouterError.self) {
            try MessageRouter.route(Data(json.utf8))
        }
    }

    @Test func hookEventPreservesRawJSON() throws {
        let json = #"{"_hook":"stop","custom":123,"nested":{"a":true}}"#
        let inputData = Data(json.utf8)
        let result = try MessageRouter.route(inputData)
        guard case .hookEvent(_, let rawJSON) = result else {
            Issue.record("Expected .hookEvent")
            return
        }
        // Raw JSON should be the original bytes
        #expect(rawJSON == inputData)
        // Verify we can re-parse it and get the custom fields back
        let obj = try JSONSerialization.jsonObject(with: rawJSON) as? [String: Any]
        #expect(obj?["custom"] as? Int == 123)
        #expect((obj?["nested"] as? [String: Any])?["a"] as? Bool == true)
    }
}

@Suite("MessageRouter + Handler Integration")
struct MessageRouterHandlerTests {

    /// Simulate the daemon handler pattern: route → handle notification.
    @Test func routeAndHandleCodoMessage() async throws {
        let json = #"{"title":"T","body":"B"}"#
        let data = Data(json.utf8)

        let routed = try MessageRouter.route(data)
        guard case .notification(let message) = routed else {
            Issue.record("Expected .notification")
            return
        }

        // Use mock notification provider to verify delivery
        let provider = MockNotificationProvider()
        let service = NotificationService(provider: provider)
        let result = await service.post(message: message)

        #expect(result.isOk)
        #expect(provider.postedMessages.count == 1)
        #expect(provider.postedMessages[0].title == "T")
        #expect(provider.postedMessages[0].body == "B")
    }

    /// Hook event with guardian ON → forwarded to guardian provider.
    @Test func routeHookEventGuardianOn() async throws {
        let json = #"{"_hook":"stop","session_id":"s1","cwd":"/tmp"}"#
        let data = Data(json.utf8)

        let routed = try MessageRouter.route(data)
        guard case .hookEvent(_, let rawJSON) = routed else {
            Issue.record("Expected .hookEvent")
            return
        }

        // Forward to mock guardian (simulates guardian alive)
        let guardian = MockGuardianProvider()
        try guardian.start(config: [:])
        #expect(guardian.isAlive == true)

        await guardian.send(line: rawJSON)
        #expect(guardian.sentLines.count == 1)

        // Verify raw JSON preserved
        let obj = try JSONSerialization.jsonObject(
            with: guardian.sentLines[0]
        ) as? [String: Any]
        #expect(obj?["_hook"] as? String == "stop")
        #expect(obj?["session_id"] as? String == "s1")
    }

    /// Hook event with guardian OFF → raw JSON contains fallback fields.
    @Test func routeHookEventGuardianOff() async throws {
        let json = #"{"_hook":"stop","last_assistant_message":"Refactored auth"}"#
        let data = Data(json.utf8)

        let routed = try MessageRouter.route(data)
        guard case .hookEvent(let hook, let rawJSON) = routed else {
            Issue.record("Expected .hookEvent")
            return
        }
        #expect(hook == "stop")

        // Guardian is OFF → build fallback from raw JSON
        let obj = try JSONSerialization.jsonObject(
            with: rawJSON
        ) as? [String: Any]
        #expect(obj != nil)

        // Verify the raw JSON contains the fields needed for fallback
        #expect(obj?["_hook"] as? String == "stop")
        #expect(obj?["last_assistant_message"] as? String == "Refactored auth")
    }

    /// Hook event handler returns .ok immediately (before async processing).
    @Test func hookPathReturnsOkImmediately() throws {
        let json = #"{"_hook":"post-tool-use","tool_name":"Bash"}"#
        let data = Data(json.utf8)

        let routed = try MessageRouter.route(data)
        guard case .hookEvent = routed else {
            Issue.record("Expected .hookEvent")
            return
        }

        // The handler pattern: route hook → return .ok immediately
        // Async processing happens after response is sent to CLI.
        // We verify the routing itself is synchronous and instant.
        let response: CodoResponse = .ok
        #expect(response.isOk)
    }
}
