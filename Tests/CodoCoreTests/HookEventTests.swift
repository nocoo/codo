import Foundation
import Testing
@testable import CodoCore

@Suite("HookEvent Decoding")
struct HookEventTests {
    @Test("decode full hook event with all fields")
    func decodeAllFields() throws {
        let json = """
        {
            "_hook": "stop",
            "session_id": "s-abc-123",
            "cwd": "/Users/test/project",
            "model": "claude-sonnet-4-6",
            "hook_event_name": "Stop"
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(event.hook == "stop")
        #expect(event.sessionId == "s-abc-123")
        #expect(event.cwd == "/Users/test/project")
        #expect(event.model == "claude-sonnet-4-6")
        #expect(event.hookEventName == "Stop")
    }

    @Test("decode minimal hook event with only required field")
    func decodeMinimal() throws {
        let json = """
        {"_hook": "notification"}
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(event.hook == "notification")
        #expect(event.sessionId == nil)
        #expect(event.cwd == nil)
        #expect(event.model == nil)
        #expect(event.hookEventName == nil)
    }

    @Test("decode session-start event")
    func decodeSessionStart() throws {
        let json = """
        {
            "_hook": "session-start",
            "session_id": "sess-1",
            "cwd": "/tmp/proj",
            "model": "claude-sonnet-4-6",
            "hook_event_name": "SessionStart"
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(event.hook == "session-start")
        #expect(event.sessionId == "sess-1")
        #expect(event.cwd == "/tmp/proj")
    }

    @Test("decode session-end event without cwd")
    func decodeSessionEndNoCwd() throws {
        let json = """
        {
            "_hook": "session-end",
            "session_id": "sess-1",
            "hook_event_name": "SessionEnd"
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(event.hook == "session-end")
        #expect(event.sessionId == "sess-1")
        #expect(event.cwd == nil)
    }

    @Test("extra fields are ignored")
    func extraFieldsIgnored() throws {
        let json = """
        {
            "_hook": "post-tool-use",
            "session_id": "s-1",
            "tool_name": "Bash",
            "tool_input": {"command": "ls"},
            "last_assistant_message": "Done"
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(event.hook == "post-tool-use")
        #expect(event.sessionId == "s-1")
    }

    @Test("missing _hook field fails decode")
    func missingHookFieldFails() throws {
        let json = """
        {"session_id": "s-1", "cwd": "/tmp"}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        }
    }
}
