import CodoCore
import Foundation

/// Minimal test server for L3 integration tests.
/// Starts a SocketServer on the given path, prints READY to stderr, waits for SIGTERM.
/// Message handler returns ok for all valid messages, except title "fail-me" which returns error.
@main
struct CodoTestServer {
    static func main() throws {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: CodoTestServer <socket-path>\n", stderr)
            exit(1)
        }

        let socketPath = CommandLine.arguments[1]

        let server = SocketServer(socketPath: socketPath) { message in
            if message.title == "fail-me" {
                return .error("test error")
            }
            return .ok
        }

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
