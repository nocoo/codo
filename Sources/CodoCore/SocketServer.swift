import Foundation

/// Unix Domain Socket server for receiving CodoMessage requests.
public final class SocketServer: Sendable {
    /// Handler called for each valid message. Returns a CodoResponse.
    public typealias MessageHandler = @Sendable (CodoMessage) -> CodoResponse

    private let socketPath: String
    private let handler: MessageHandler
    private nonisolated(unsafe) var serverSocket: Int32 = -1
    private nonisolated(unsafe) var running = false

    /// Maximum payload size: 64KB
    public static let maxPayloadSize = 65_536

    /// Read/write timeout: 5 seconds
    private static let timeoutSeconds: Int = 5

    public init(socketPath: String, handler: @escaping MessageHandler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    /// Start listening on the Unix Domain Socket.
    public func start() throws {
        // Create socket directory if needed
        let dir = (socketPath as NSString).deletingLastPathComponent
        let dirExisted = FileManager.default.fileExists(atPath: dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Only set permissions on directories we created, not pre-existing ones like /tmp
        if !dirExisted {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: dir
            )
        }

        // Handle stale socket
        if FileManager.default.fileExists(atPath: socketPath) {
            if isSocketAlive(at: socketPath) {
                throw SocketServerError.alreadyRunning
            }
            try FileManager.default.removeItem(atPath: socketPath)
        }

        // Create socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw SocketServerError.socketCreationFailed(errno: errno)
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(serverSocket)
            throw SocketServerError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(serverSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(serverSocket)
            throw SocketServerError.bindFailed(errno: errno)
        }

        // Set socket permissions to 0600
        chmod(socketPath, 0o600)

        // Listen
        guard Darwin.listen(serverSocket, 5) == 0 else {
            Darwin.close(serverSocket)
            unlink(socketPath)
            throw SocketServerError.listenFailed(errno: errno)
        }

        running = true

        // Accept loop on a dedicated thread (blocking calls must not run on cooperative pool)
        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Stop the server and clean up.
    public func stop() {
        running = false
        if serverSocket >= 0 {
            Darwin.close(serverSocket)
            serverSocket = -1
        }
        unlink(socketPath)
    }

    // MARK: - Private

    private func acceptLoop() {
        while running {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(serverSocket, sockPtr, &clientAddrLen)
                }
            }

            guard clientSocket >= 0 else {
                if !running { break }
                continue
            }

            // Handle client on a dispatch queue to avoid blocking accept thread
            let handler = self.handler
            DispatchQueue.global(qos: .userInitiated).async {
                Self.handleClient(socket: clientSocket, handler: handler)
            }
        }
    }

    private static func handleClient(
        socket clientSocket: Int32,
        handler: MessageHandler
    ) {
        defer { Darwin.close(clientSocket) }

        // Set read timeout
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientSocket, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Read data until newline or timeout
        var buffer = Data()
        let chunkSize = 4096
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        while buffer.count < maxPayloadSize {
            let bytesRead = recv(clientSocket, &chunk, chunkSize, 0)
            if bytesRead <= 0 { break }
            buffer.append(contentsOf: chunk[0..<bytesRead])
            if buffer.contains(UInt8(ascii: "\n")) { break }
        }

        // Reject oversized payload
        guard buffer.count <= maxPayloadSize else {
            return // close without response per protocol spec
        }

        // Trim trailing newline
        if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            buffer = buffer[buffer.startIndex..<newlineIndex]
        }

        guard !buffer.isEmpty else { return }

        // Decode message
        let response: CodoResponse
        do {
            let message = try JSONDecoder().decode(CodoMessage.self, from: buffer)
            if let validationError = message.validate() {
                response = .error(validationError)
            } else {
                response = handler(message)
            }
        } catch {
            response = .error("invalid json")
        }

        // Send response
        sendResponse(response, to: clientSocket)
    }

    private static func sendResponse(_ response: CodoResponse, to clientSocket: Int32) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = Darwin.send(clientSocket, base, ptr.count, 0)
        }
    }

    private func isSocketAlive(at path: String) -> Bool {
        let testSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard testSocket >= 0 else { return false }
        defer { Darwin.close(testSocket) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(testSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }
}

// MARK: - Errors

public enum SocketServerError: Error, CustomStringConvertible {
    case alreadyRunning
    case socketCreationFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case pathTooLong

    public var description: String {
        switch self {
        case .alreadyRunning:
            return "another codo instance is already running"
        case .socketCreationFailed(let code):
            return "socket creation failed: \(String(cString: strerror(code)))"
        case .bindFailed(let code):
            return "bind failed: \(String(cString: strerror(code)))"
        case .listenFailed(let code):
            return "listen failed: \(String(cString: strerror(code)))"
        case .pathTooLong:
            return "socket path too long"
        }
    }
}
