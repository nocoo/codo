import Foundation

/// Client for connecting to the Codo daemon via Unix Domain Socket.
public enum SocketClient {
    /// Send a message to the daemon and return the response.
    /// Throws if the socket is not available or communication fails.
    public static func send(
        _ message: CodoMessage,
        socketPath: String
    ) throws -> CodoResponse {
        // Check socket exists
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw SocketClientError.daemonNotRunning
        }

        // Create socket
        let clientSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard clientSocket >= 0 else {
            throw SocketClientError.connectionFailed(
                reason: String(cString: strerror(errno))
            )
        }
        defer { close(clientSocket) }

        // Set timeout
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientSocket, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Connect
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(clientSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw SocketClientError.connectionFailed(
                reason: String(cString: strerror(errno))
            )
        }

        // Send
        var data = try JSONEncoder().encode(message)
        data.append(UInt8(ascii: "\n"))
        let sent = data.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return Darwin.send(clientSocket, base, ptr.count, 0)
        }
        guard sent == data.count else {
            throw SocketClientError.sendFailed
        }

        // Read response
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = recv(clientSocket, &chunk, chunk.count, 0)
            if bytesRead <= 0 { break }
            buffer.append(contentsOf: chunk[0..<bytesRead])
            if buffer.contains(UInt8(ascii: "\n")) { break }
        }

        // Trim newline
        if let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            buffer = buffer[buffer.startIndex..<idx]
        }

        guard !buffer.isEmpty else {
            throw SocketClientError.emptyResponse
        }

        return try JSONDecoder().decode(CodoResponse.self, from: buffer)
    }

    /// Send raw bytes to the socket (for testing invalid input).
    public static func sendRaw(
        _ rawData: Data,
        socketPath: String
    ) throws -> Data {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw SocketClientError.daemonNotRunning
        }

        let clientSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard clientSocket >= 0 else {
            throw SocketClientError.connectionFailed(
                reason: String(cString: strerror(errno))
            )
        }
        defer { close(clientSocket) }

        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientSocket, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(clientSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw SocketClientError.connectionFailed(
                reason: String(cString: strerror(errno))
            )
        }

        let sent = rawData.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return Darwin.send(clientSocket, base, ptr.count, 0)
        }
        guard sent == rawData.count else {
            throw SocketClientError.sendFailed
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = recv(clientSocket, &chunk, chunk.count, 0)
            if bytesRead <= 0 { break }
            buffer.append(contentsOf: chunk[0..<bytesRead])
            if buffer.contains(UInt8(ascii: "\n")) { break }
        }

        return buffer
    }
}

public enum SocketClientError: Error, CustomStringConvertible {
    case daemonNotRunning
    case connectionFailed(reason: String)
    case sendFailed
    case emptyResponse
    case timeout

    public var description: String {
        switch self {
        case .daemonNotRunning:
            return "codo daemon not running"
        case .connectionFailed(let reason):
            return "cannot connect to codo daemon: \(reason)"
        case .sendFailed:
            return "send failed"
        case .emptyResponse:
            return "unexpected response from daemon"
        case .timeout:
            return "timeout"
        }
    }
}
