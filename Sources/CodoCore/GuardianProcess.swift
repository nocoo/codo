import Foundation

/// Manages the Guardian child process lifecycle.
///
/// Communication model:
/// - Daemon writes JSON lines to stdin (fire-and-forget, never blocks)
/// - A background thread reads stdout lines and decodes GuardianAction
/// - When action == "send", it posts the notification via NotificationService
/// - All stdin writes are serialized through a DispatchQueue
/// - All stdout reads happen on a dedicated Thread (same pattern as SocketServer accept loop)
public final class GuardianProcess: GuardianProvider, @unchecked Sendable {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private let writeQueue = DispatchQueue(label: "codo.guardian.stdin")
    private let notificationService: NotificationService
    private let bunPath: String
    private let guardianPath: String
    private var restartCount: Int = 0
    private let maxRestarts = 3
    private var disabled = false

    public init(
        notificationService: NotificationService,
        guardianPath: String,
        bunPath: String = "/usr/local/bin/bun"
    ) {
        self.notificationService = notificationService
        self.guardianPath = guardianPath
        self.bunPath = bunPath
    }

    public var isAlive: Bool {
        process?.isRunning ?? false
    }

    /// Send raw JSON line to Guardian stdin. Serialized via writeQueue.
    public func send(line: Data) async {
        writeQueue.async { [weak self] in
            guard let pipe = self?.stdinPipe, self?.isAlive == true else { return }
            var data = line
            data.append(UInt8(ascii: "\n"))
            pipe.fileHandleForWriting.write(data)
        }
    }

    /// Start the Guardian process with given environment config.
    public func start(config: [String: String]) throws {
        guard !disabled else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bunPath)
        proc.arguments = [guardianPath]
        proc.environment = ProcessInfo.processInfo.environment.merging(config) { _, new in new }

        let stdin = Pipe()
        let stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice

        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.process = proc

        // Monitor for unexpected termination
        proc.terminationHandler = { [weak self] _ in
            self?.handleTermination()
        }

        try proc.run()

        // Start background stdout reader
        let thread = Thread { [weak self] in
            self?.readStdoutLoop()
        }
        thread.qualityOfService = .userInitiated
        thread.name = "codo.guardian.stdout"
        thread.start()
    }

    /// Stop the Guardian process (SIGTERM).
    public func stop() {
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
    }

    // MARK: - Private

    /// Handle unexpected Guardian process termination.
    private func handleTermination() {
        guard !disabled else { return }
        restartCount += 1
        if restartCount > maxRestarts {
            disabled = true
            return
        }
        // Auto-restart is deferred to AppDelegate which checks isAlive
    }

    /// Background stdout reader. Decodes each line as GuardianAction.
    private func readStdoutLoop() {
        guard let handle = stdoutPipe?.fileHandleForReading else { return }

        var buffer = Data()
        let decoder = JSONDecoder()

        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break } // EOF

            buffer.append(chunk)

            // Process complete lines
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = buffer[buffer.index(after: newlineIndex)...]

                guard !lineData.isEmpty else { continue }

                do {
                    let action = try decoder.decode(GuardianAction.self, from: Data(lineData))
                    if action.action == "send", let notification = action.notification {
                        // Post notification asynchronously
                        Task {
                            _ = await notificationService.post(message: notification)
                        }
                    }
                    // "suppress" → no action, optionally log reason
                } catch {
                    // Malformed line — skip, don't crash
                    continue
                }
            }
        }
    }
}
