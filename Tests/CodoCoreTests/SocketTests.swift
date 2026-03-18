import Foundation
import Testing

@testable import CodoCore

/// Helper to create a temp socket path for testing.
/// Unix socket paths have a max length (~104 bytes on macOS), so keep it short.
private func tempSocketPath() -> String {
    let id = String(UUID().uuidString.prefix(8))
    return "/tmp/codo-\(id).sock"
}

/// Helper to create a temp socket path inside a subdirectory (for permission tests).
private func tempSocketPathInDir() -> String {
    let id = String(UUID().uuidString.prefix(8))
    return "/tmp/cd-\(id)/codo.sock"
}

// MARK: - Socket Roundtrip

@Suite("Socket Roundtrip")
struct SocketRoundtripTests {
    @Test func happyPath() async throws {
        let path = tempSocketPath()
        let server = SocketServer(socketPath: path) { _ in .ok }
        try server.start()
        defer { server.stop() }

        try await Task.sleep(for: .milliseconds(100))

        let msg = CodoMessage(title: "Test", body: nil, sound: nil)
        let response = try SocketClient.send(msg, socketPath: path)
        #expect(response.isOk == true)
    }

    @Test func handlerReturnsError() async throws {
        let path = tempSocketPath()
        let server = SocketServer(socketPath: path) { _ in
            .error("test error")
        }
        try server.start()
        defer { server.stop() }

        try await Task.sleep(for: .milliseconds(100))

        let msg = CodoMessage(title: "Test", body: nil, sound: nil)
        let response = try SocketClient.send(msg, socketPath: path)
        #expect(response.isOk == false)
        #expect(response.errorMessage == "test error")
    }

    @Test func invalidJson() async throws {
        let path = tempSocketPath()
        let server = SocketServer(socketPath: path) { _ in .ok }
        try server.start()
        defer { server.stop() }

        try await Task.sleep(for: .milliseconds(100))

        let raw = Data("not json\n".utf8)
        let responseData = try SocketClient.sendRaw(raw, socketPath: path)
        let responseStr = String(data: responseData, encoding: .utf8) ?? ""
        #expect(responseStr.contains("invalid json"))
    }

    @Test func missingTitle() async throws {
        let path = tempSocketPath()
        let server = SocketServer(socketPath: path) { _ in .ok }
        try server.start()
        defer { server.stop() }

        try await Task.sleep(for: .milliseconds(100))

        let raw = Data(#"{"body":"B"}"#.utf8 + [UInt8(ascii: "\n")])
        let responseData = try SocketClient.sendRaw(raw, socketPath: path)
        let responseStr = String(data: responseData, encoding: .utf8) ?? ""
        // body without title → DecodingError → "invalid json"
        #expect(responseStr.contains("invalid json"))
    }

    @Test func emptyTitle() async throws {
        let path = tempSocketPath()
        let server = SocketServer(socketPath: path) { _ in .ok }
        try server.start()
        defer { server.stop() }

        try await Task.sleep(for: .milliseconds(100))

        let raw = Data(#"{"title":""}"#.utf8 + [UInt8(ascii: "\n")])
        let responseData = try SocketClient.sendRaw(raw, socketPath: path)
        let responseStr = String(data: responseData, encoding: .utf8) ?? ""
        #expect(responseStr.contains("title is required"))
    }

    @Test func serverNotRunning() throws {
        let path = tempSocketPath()
        let msg = CodoMessage(title: "Test", body: nil, sound: nil)
        #expect(throws: SocketClientError.self) {
            try SocketClient.send(msg, socketPath: path)
        }
    }

    @Test func messageWithBodyAndSound() async throws {
        let path = tempSocketPath()
        let server = SocketServer(socketPath: path) { _ in .ok }
        try server.start()
        defer { server.stop() }

        try await Task.sleep(for: .milliseconds(100))

        let msg = CodoMessage(title: "T", body: "B", sound: "none")
        let response = try SocketClient.send(msg, socketPath: path)
        #expect(response.isOk == true)
    }
}

// MARK: - Socket Lifecycle

@Suite("Socket Lifecycle")
struct SocketLifecycleTests {
    @Test func staleSocketCleanup() async throws {
        let path = tempSocketPathInDir()
        // Create stale socket file
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: path, contents: nil)

        // Server should clean up and bind successfully
        let server = SocketServer(socketPath: path) { _ in .ok }
        try server.start()
        defer { server.stop() }

        try await Task.sleep(for: .milliseconds(100))

        let msg = CodoMessage(title: "Test", body: nil, sound: nil)
        let response = try SocketClient.send(msg, socketPath: path)
        #expect(response.isOk == true)
    }

    @Test func concurrentClients() async throws {
        let path = tempSocketPath()
        let server = SocketServer(socketPath: path) { _ in .ok }
        try server.start()
        defer { server.stop() }

        try await Task.sleep(for: .milliseconds(100))

        // Send 3 messages concurrently
        try await withThrowingTaskGroup(of: CodoResponse.self) { group in
            for idx in 0..<3 {
                group.addTask {
                    let msg = CodoMessage(
                        title: "Msg \(idx)", body: nil, sound: nil
                    )
                    return try SocketClient.send(msg, socketPath: path)
                }
            }

            var count = 0
            for try await response in group {
                #expect(response.isOk == true)
                count += 1
            }
            #expect(count == 3)
        }
    }

    @Test func directoryPermissions() throws {
        let path = tempSocketPathInDir()
        let server = SocketServer(socketPath: path) { _ in .ok }
        try server.start()
        defer { server.stop() }

        let dir = (path as NSString).deletingLastPathComponent
        let attrs = try FileManager.default.attributesOfItem(atPath: dir)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o700)
    }
}
