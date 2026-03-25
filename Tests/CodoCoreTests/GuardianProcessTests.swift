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

    @Test("restart/crash-loop logic is covered by CrashLoopBreakerTests")
    func crashLoopCoverage() {
        // The real crash-loop detection (restartCount, disabled, stability timer)
        // is in CrashLoopBreaker, fully tested in CrashLoopBreakerTests.
        // GuardianProcess delegates to CrashLoopBreaker via injection.
        // Here we just verify the mock's basic start/stop cycle works.
        let mock = MockGuardianProvider()
        #expect(mock.isAlive == false)
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

@Suite("GuardianProcess killOrphans")
struct KillOrphansTests {

    @Test("killOrphans with non-matching path does not crash")
    func killOrphansNonMatching() {
        // Use a path that no running process could match
        let fakePath = "/nonexistent/\(UUID().uuidString)/guardian/main.ts"
        // Should complete without error — pgrep returns empty, no kills
        GuardianProcess.killOrphans(guardianPath: fakePath)
        // If we get here without crashing, the test passes
    }

    @Test("killOrphans does not kill the test process itself")
    func killOrphansSkipsSelf() {
        // The method filters out ProcessInfo.processInfo.processIdentifier.
        // Use the test binary's own command line as the search path — pgrep -f
        // will match this process, but killOrphans should skip it (myPid filter)
        // and also skip it because PPID != 1 (test runner is our parent, not launchd).
        let myPid = ProcessInfo.processInfo.processIdentifier
        let args = ProcessInfo.processInfo.arguments
        guard let binaryPath = args.first else { return }

        // This won't actually match "guardian/main.ts" in our command line,
        // but we can verify the pgrep + PPID filter logic doesn't crash
        // when called with a real path that exists on disk
        GuardianProcess.killOrphans(guardianPath: binaryPath)

        // Verify we're still alive (the method didn't kill us)
        #expect(ProcessInfo.processInfo.processIdentifier == myPid)
    }
}
