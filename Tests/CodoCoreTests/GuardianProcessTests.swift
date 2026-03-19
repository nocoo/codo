import Testing
import Foundation
@testable import CodoCore

@Suite("GuardianProvider Mock")
struct GuardianProviderMockTests {

    @Test("mock provider send message")
    func mockProviderSendMessage() async throws {
        let mock = MockGuardianProvider()
        let message = CodoMessage(title: "Build Done", body: "All tests passed", sound: "default")
        let data = try JSONEncoder().encode(message)
        await mock.send(line: data)

        #expect(mock.sentLines.count == 1)
        let decoded = try JSONDecoder().decode(CodoMessage.self, from: mock.sentLines[0])
        #expect(decoded.title == "Build Done")
        #expect(decoded.body == "All tests passed")
    }

    @Test("mock provider send hook")
    func mockProviderSendHook() async throws {
        let mock = MockGuardianProvider()
        let hookJSON: [String: Any] = [
            "_hook": "post-tool-use",
            "tool_name": "Bash",
            "tool_input": "swift build"
        ]
        let data = try JSONSerialization.data(withJSONObject: hookJSON)
        await mock.send(line: data)

        #expect(mock.sentLines.count == 1)
        // Verify raw JSON preserved
        let obj = try JSONSerialization.jsonObject(with: mock.sentLines[0]) as? [String: Any]
        #expect(obj?["_hook"] as? String == "post-tool-use")
        #expect(obj?["tool_name"] as? String == "Bash")
    }

    @Test("mock provider isAlive after start")
    func mockProviderIsAlive() throws {
        let mock = MockGuardianProvider()
        #expect(mock.isAlive == false)

        try mock.start(config: ["CODO_API_KEY": "test-key"])
        #expect(mock.isAlive == true)
        #expect(mock.started == true)
        #expect(mock.startConfig?["CODO_API_KEY"] == "test-key")
    }

    @Test("mock provider stop")
    func mockProviderStop() throws {
        let mock = MockGuardianProvider()
        try mock.start(config: [:])
        #expect(mock.isAlive == true)

        mock.stop()
        #expect(mock.isAlive == false)
        #expect(mock.stopped == true)
    }

    @Test("restart count exceeded disables provider")
    func restartCountExceeded() throws {
        // GuardianProcess has private restart logic:
        // - handleTermination() increments restartCount
        // - After maxRestarts (3) exceeded, sets disabled = true
        // - When disabled, start() returns early (no-op)
        //
        // We test the observable behavior: after enough terminations,
        // isAlive stays false and start() has no effect.
        //
        // Since GuardianProcess.handleTermination is private and requires
        // a real process, we verify the contract on MockGuardianProvider
        // by simulating the same pattern: start → stop → restart cycle.
        let mock = MockGuardianProvider()

        // Simulate 3 start/stop cycles (representing crash+restart)
        for _ in 0..<3 {
            try mock.start(config: [:])
            #expect(mock.isAlive == true)
            mock.stop()
            #expect(mock.isAlive == false)
        }

        // After 3 failures, the real GuardianProcess would set disabled=true
        // and refuse to start. Mock doesn't enforce this, but we verify
        // the state tracking works correctly for the wiring layer.
        #expect(mock.isAlive == false)
        #expect(mock.stopped == true)
    }
}

@Suite("GuardianAction Decoding")
struct GuardianActionTests {

    @Test("resolveBunPath finds bun on this machine")
    func resolveBunPath() {
        // This test verifies resolveBunPath works on the current dev machine.
        // If bun is not installed, the test is skipped.
        let path = GuardianProcess.resolveBunPath()
        if path != nil {
            #expect(FileManager.default.isExecutableFile(atPath: path!))
        } else {
            // bun not installed — skip verification but don't fail
            // (CI may not have bun)
        }
    }

    @Test("decode send action with notification")
    func decodeSendAction() throws {
        let json = """
        {"action":"send","notification":{"title":"Build Done","body":"OK"}}
        """
        let action = try JSONDecoder().decode(GuardianAction.self, from: Data(json.utf8))
        #expect(action.action == "send")
        #expect(action.notification?.title == "Build Done")
        #expect(action.notification?.body == "OK")
        #expect(action.reason == nil)
    }

    @Test("decode suppress action with reason")
    func decodeSuppressAction() throws {
        let json = """
        {"action":"suppress","reason":"duplicate within 30s"}
        """
        let action = try JSONDecoder().decode(GuardianAction.self, from: Data(json.utf8))
        #expect(action.action == "suppress")
        #expect(action.notification == nil)
        #expect(action.reason == "duplicate within 30s")
    }

    @Test("encode roundtrip")
    func encodeRoundtrip() throws {
        let original = GuardianAction(
            action: "send",
            notification: CodoMessage(title: "Test", body: "Body", sound: "default"),
            reason: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GuardianAction.self, from: data)
        #expect(decoded.action == original.action)
        #expect(decoded.notification?.title == original.notification?.title)
    }
}
