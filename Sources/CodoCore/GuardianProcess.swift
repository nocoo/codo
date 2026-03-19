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
    private var intentionalStop = false
    private var lastConfig: [String: String]?

    /// Called on main queue when Guardian gives up after maxRestarts.
    public var onDisabled: (() -> Void)?

    public init(
        notificationService: NotificationService,
        guardianPath: String,
        bunPath: String
    ) {
        self.notificationService = notificationService
        self.guardianPath = guardianPath
        self.bunPath = bunPath
    }

    public var isAlive: Bool {
        process?.isRunning ?? false
    }

    /// Resolve the bun executable path by checking common locations
    /// and falling back to `which bun`.
    public static func resolveBunPath() -> String? {
        // Check common paths in priority order
        let candidates = [
            "/opt/homebrew/bin/bun",    // Apple Silicon Homebrew
            "/usr/local/bin/bun",       // Intel Homebrew / manual install
            "\(NSHomeDirectory())/.bun/bin/bun" // bun self-install
        ]

        let fileManager = FileManager.default
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return path
        }

        // Fall back to `which bun` for PATH-based installs
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["bun"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, fileManager.isExecutableFile(atPath: path) {
                    return path
                }
            }
        } catch {
            // which failed, no bun found
        }

        return nil
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

        intentionalStop = false
        lastConfig = config

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

    /// Stop the Guardian process (SIGTERM). Intentional stop — no auto-restart.
    public func stop() {
        intentionalStop = true
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
    }

    // MARK: - Private

    /// Handle unexpected Guardian process termination.
    /// Attempts auto-restart up to maxRestarts times with a 1s delay.
    private func handleTermination() {
        // If stop() was called intentionally, don't auto-restart
        guard !intentionalStop, !disabled else { return }

        restartCount += 1
        if restartCount > maxRestarts {
            disabled = true
            DispatchQueue.main.async { [weak self] in
                self?.onDisabled?()
            }
            return
        }

        // Clear old pipes before restart
        process = nil
        stdinPipe = nil
        stdoutPipe = nil

        // Restart after a short delay to avoid tight crash loops
        guard let config = lastConfig else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + 1.0
        ) { [weak self] in
            do {
                try self?.start(config: config)
            } catch {
                // Restart failed — will try again on next termination
            }
        }
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
