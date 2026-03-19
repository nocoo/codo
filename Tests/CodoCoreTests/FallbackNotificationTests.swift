import Foundation
import Testing

@testable import CodoCore

@Suite("FallbackNotification")
struct FallbackNotificationTests {

    @Test func fallbackNotification() throws {
        let json: [String: Any] = [
            "_hook": "notification",
            "title": "Permission needed",
            "message": "Approve Bash?"
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let result = FallbackNotification.build(from: data)
        #expect(result?.title == "Permission needed")
        #expect(result?.body == "Approve Bash?")
    }

    @Test func fallbackNotificationNoTitle() throws {
        let json: [String: Any] = [
            "_hook": "notification",
            "message": "Some message"
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let result = FallbackNotification.build(from: data)
        #expect(result?.title == "Codo")
        #expect(result?.body == "Some message")
    }

    @Test func fallbackStop() throws {
        let json: [String: Any] = [
            "_hook": "stop",
            "last_assistant_message": "Refactored auth module"
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let result = FallbackNotification.build(from: data)
        #expect(result?.title == "Task Complete")
        #expect(result?.body == "Refactored auth module")
    }

    @Test func fallbackStopLongMessage() throws {
        let longMsg = String(repeating: "a", count: 150)
        let json: [String: Any] = [
            "_hook": "stop",
            "last_assistant_message": longMsg
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let result = FallbackNotification.build(from: data)
        #expect(result?.title == "Task Complete")
        #expect(result?.body?.count == 103) // 100 + "..."
        #expect(result?.body?.hasSuffix("...") == true)
    }

    @Test func fallbackPostToolUseImportant() throws {
        let json: [String: Any] = [
            "_hook": "post-tool-use",
            "tool_name": "Bash",
            "command": "npm test",
            "tool_response": "42 tests passed"
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let result = FallbackNotification.build(from: data)
        #expect(result?.title == "Bash result")
        #expect(result?.body == "42 tests passed")
    }

    @Test func fallbackPostToolUseNoise() throws {
        let json: [String: Any] = [
            "_hook": "post-tool-use",
            "tool_name": "Bash",
            "command": "ls -la"
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let result = FallbackNotification.build(from: data)
        #expect(result == nil) // suppressed
    }

    @Test func fallbackPostToolUseFailure() throws {
        let json: [String: Any] = [
            "_hook": "post-tool-use-failure",
            "tool_name": "Bash",
            "error": "Command failed with exit code 1"
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let result = FallbackNotification.build(from: data)
        #expect(result?.title == "Bash failed")
        #expect(result?.body == "Command failed with exit code 1")
    }

    @Test func fallbackSessionStart() throws {
        let json: [String: Any] = [
            "_hook": "session-start",
            "model": "claude-sonnet-4-6"
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let result = FallbackNotification.build(from: data)
        #expect(result?.title == "Session Started")
        #expect(result?.body == "claude-sonnet-4-6")
    }

    @Test func fallbackSessionEnd() throws {
        let json: [String: Any] = [
            "_hook": "session-end",
            "session_id": "s1"
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let result = FallbackNotification.build(from: data)
        #expect(result == nil) // suppressed
    }

    @Test func fallbackInvalidJSON() {
        let data = Data("not json".utf8)
        let result = FallbackNotification.build(from: data)
        #expect(result == nil)
    }

    @Test func fallbackMissingHook() throws {
        let json: [String: Any] = ["title": "no hook"]
        let data = try JSONSerialization.data(withJSONObject: json)
        let result = FallbackNotification.build(from: data)
        #expect(result == nil)
    }

    @Test func isImportantCommand() {
        #expect(FallbackNotification.isImportantCommand("npm test") == true)
        #expect(FallbackNotification.isImportantCommand("swift build") == true)
        #expect(FallbackNotification.isImportantCommand("swift test") == true)
        #expect(FallbackNotification.isImportantCommand("git commit -m 'x'") == true)
        #expect(FallbackNotification.isImportantCommand("git push") == true)
        #expect(FallbackNotification.isImportantCommand("bun test") == true)
        #expect(FallbackNotification.isImportantCommand("cargo build") == true)
        #expect(FallbackNotification.isImportantCommand("ls -la") == false)
        #expect(FallbackNotification.isImportantCommand("cat file.txt") == false)
        #expect(FallbackNotification.isImportantCommand("echo hello") == false)
    }

    @Test func truncate() {
        #expect(FallbackNotification.truncate(nil, maxLength: 10) == nil)
        #expect(FallbackNotification.truncate("", maxLength: 10) == nil)
        #expect(FallbackNotification.truncate("short", maxLength: 10) == "short")
        #expect(FallbackNotification.truncate("exactly ten", maxLength: 11) == "exactly ten")
        let long = FallbackNotification.truncate("this is too long", maxLength: 7)
        #expect(long == "this is...")
    }
}
