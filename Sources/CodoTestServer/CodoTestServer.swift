import CodoCore
import Foundation

/// Minimal test server for L3 integration tests.
/// Starts a SocketServer on the given path, prints READY to stderr, waits for SIGTERM.
/// Uses RawMessageHandler + MessageRouter to handle both CodoMessage and hook events.
/// All received payloads are logged as JSON lines to `messages.log` in the socket directory.
@main
struct CodoTestServer {
    static func main() throws {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: CodoTestServer <socket-path>\n", stderr)
            exit(1)
        }

        let socketPath = CommandLine.arguments[1]
        let socketDir = (socketPath as NSString).deletingLastPathComponent
        let logPath = (socketDir as NSString).appendingPathComponent("messages.log")

        // Create or truncate the log file
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logPath)!
        let logQueue = DispatchQueue(label: "codo.test-server.log")

        let server = SocketServer(socketPath: socketPath, rawHandler: { data in
            do {
                let routed = try MessageRouter.route(data)
                switch routed {
                case .notification(let message):
                    // Log the CodoMessage as JSON
                    if let encoded = try? JSONEncoder().encode(message),
                       let line = String(data: encoded, encoding: .utf8) {
                        let entry = line + "\n"
                        logQueue.sync {
                            logHandle.write(Data(entry.utf8))
                        }
                    }
                    if message.title == "fail-me" {
                        return .error("test error")
                    }
                    return .ok

                case .hookEvent(_, let rawJSON):
                    // Log the raw hook event JSON bytes as-is
                    if let line = String(data: rawJSON, encoding: .utf8) {
                        let entry = line + "\n"
                        logQueue.sync {
                            logHandle.write(Data(entry.utf8))
                        }
                    }
                    return .ok
                }
            } catch {
                return .error("invalid json")
            }
        })

        try server.start()
        fputs("READY\n", stderr)

        // Handle SIGTERM for clean shutdown
        signal(SIGTERM) { _ in
            exit(0)
        }
        signal(SIGINT) { _ in
            exit(0)
        }

        // Block forever
        dispatchMain()
    }
}
