import Foundation
import os

private let logger = Logger(subsystem: "ai.hexly.codo.04", category: "guardian")

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
    private var stderrPipe: Pipe?
    private let writeQueue = DispatchQueue(label: "codo.guardian.stdin")
    private let lifecycleQueue = DispatchQueue(label: "codo.guardian.lifecycle")
    private let notificationService: NotificationService
    private let bunPath: String
    private let guardianPath: String
    private var intentionalStop = false
    private var lastConfig: [String: String]?
    private let crashBreaker: CrashLoopBreaker

    /// Called on the stdout reader thread when Guardian emits an action.
    /// Caller is responsible for thread-hopping (e.g. Task { @MainActor in }).
    public var onAction: (@Sendable (GuardianAction) -> Void)?

    /// Called on main queue when Guardian gives up after repeated crashes.
    public var onDisabled: (() -> Void)? {
        didSet {
            crashBreaker.onTripped = { [weak self] in
                DispatchQueue.main.async {
                    self?.onDisabled?()
                }
            }
        }
    }

    public init(
        notificationService: NotificationService,
        guardianPath: String,
        bunPath: String,
        crashBreaker: CrashLoopBreaker = CrashLoopBreaker()
    ) {
        self.notificationService = notificationService
        self.guardianPath = guardianPath
        self.bunPath = bunPath
        self.crashBreaker = crashBreaker
    }

    public var isAlive: Bool {
        lifecycleQueue.sync { process?.isRunning ?? false }
    }

    /// Send raw JSON line to Guardian stdin. Serialized via writeQueue.
    public func send(line: Data) async {
        let pipe: Pipe? = lifecycleQueue.sync {
            guard process?.isRunning == true else { return nil }
            return stdinPipe
        }
        guard let pipe else { return }
        writeQueue.async {
            var data = line
            data.append(UInt8(ascii: "\n"))
            do {
                try pipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                logger.warning("stdin write failed: \(error.localizedDescription)")
            }
        }
    }

    /// Start the Guardian process with given environment config.
    public func start(config: [String: String]) throws {
        guard !crashBreaker.isTripped else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bunPath)
        proc.arguments = [guardianPath]
        proc.environment = ProcessInfo.processInfo.environment.merging(config) { _, new in new }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        lifecycleQueue.sync {
            intentionalStop = false
            lastConfig = config
            self.stdinPipe = stdin
            self.stdoutPipe = stdout
            self.stderrPipe = stderr
            self.process = proc
        }

        // Monitor for unexpected termination
        proc.terminationHandler = { [weak self] _ in
            self?.handleTermination()
        }

        try proc.run()
        crashBreaker.recordStart()

        // Readers capture local pipe refs — not self.stdoutPipe/stderrPipe
        let capturedStdout = stdout
        let thread = Thread { [weak self] in
            self?.readStdoutLoop(pipe: capturedStdout)
        }
        thread.qualityOfService = .userInitiated
        thread.name = "codo.guardian.stdout"
        thread.start()

        // Start background stderr reader (logs to ~/.codo/guardian.log)
        let capturedStderr = stderr
        DispatchQueue.global(qos: .utility).async {
            Self.readStderrLoop(pipe: capturedStderr)
        }
    }

    /// Stop the Guardian process (SIGTERM). Intentional stop — no auto-restart.
    public func stop() {
        lifecycleQueue.sync {
            intentionalStop = true
            if let proc = process, proc.isRunning {
                proc.terminate()
            }
            process = nil
            stdinPipe = nil
            stdoutPipe = nil
            stderrPipe = nil
        }
    }

    // MARK: - Private

    /// Handle unexpected Guardian process termination.
    /// Delegates crash tracking to CrashLoopBreaker which resets on stability.
    private func handleTermination() {
        // If stop() was called intentionally, don't auto-restart
        let wasIntentional = lifecycleQueue.sync { intentionalStop }
        guard !wasIntentional else { return }

        // Record failure outside lifecycleQueue to avoid nested sync
        // (crashBreaker uses its own serial queue internally)
        let didTrip = crashBreaker.recordFailure()
        if didTrip { return }

        // Clear old pipes before restart
        let config: [String: String]? = lifecycleQueue.sync {
            process = nil
            stdinPipe = nil
            stdoutPipe = nil
            stderrPipe = nil
            return lastConfig
        }

        // Restart after a short delay to avoid tight crash loops
        guard let config else { return }
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
    private func readStdoutLoop(pipe: Pipe) {
        let handle = pipe.fileHandleForReading

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
                    onAction?(action)
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

    /// Background stderr reader. Forwards each line to os.Logger and log file.
    /// Rotates the log file to `.1` when it exceeds 5MB (checked every 1000 lines).
    private static func readStderrLoop(pipe: Pipe) {
        let logPath = "\(NSHomeDirectory())/.codo/guardian.log"
        let maxSize: UInt64 = 5_000_000  // 5MB
        let checkInterval = 1000         // check size every N lines

        var logHandle = openOrCreateLog(at: logPath)
        var lineCount = 0

        let handle = pipe.fileHandleForReading
        let dateFormatter = ISO8601DateFormatter()

        var buffer = Data()

        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break } // EOF

            buffer.append(chunk)

            // Process complete lines
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = buffer[buffer.index(after: newlineIndex)...]

                guard !lineData.isEmpty,
                      let line = String(data: Data(lineData), encoding: .utf8) else { continue }

                logger.notice("\(line, privacy: .public)")
                let logLine = "[\(dateFormatter.string(from: Date()))] \(line)\n"
                logHandle?.write(Data(logLine.utf8))

                // Check rotation periodically
                lineCount += 1
                if lineCount % checkInterval == 0,
                   shouldRotate(path: logPath, maxSize: maxSize) {
                    logHandle?.closeFile()
                    let backupPath = "\(logPath).1"
                    try? FileManager.default.removeItem(atPath: backupPath)
                    try? FileManager.default.moveItem(atPath: logPath, toPath: backupPath)
                    logHandle = openOrCreateLog(at: logPath)
                }
            }
        }

        logHandle?.closeFile()
    }

    /// Open (or create) a log file for appending, writing a startup marker.
    private static func openOrCreateLog(at path: String) -> FileHandle? {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            fileManager.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        handle.seekToEndOfFile()
        let marker = "--- guardian stderr log started ---\n"
        handle.write(Data(marker.utf8))
        return handle
    }

    /// Check if a log file should be rotated based on size.
    private static func shouldRotate(path: String, maxSize: UInt64) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return false }
        return size > maxSize
    }
}
