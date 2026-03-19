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
