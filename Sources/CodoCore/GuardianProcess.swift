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

    /// Kill orphaned guardian processes from previous Codo sessions.
    ///
    /// Uses `pgrep -f` to find processes whose command line contains `guardianPath`.
    /// Since `guardianPath` is an absolute path (e.g. /Users/.../codo/guardian/main.ts),
    /// this won't match guardians from a different project checkout.
    /// Then filters to PPID == 1 (adopted by launchd = true orphans), so it won't
    /// kill a guardian actively managed by a running Codo instance.
    public static func killOrphans(guardianPath: String) {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", guardianPath]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice

        do {
            try pgrep.run()
        } catch {
            return
        }
        pgrep.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }

        let pids = output.split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        let myPid = ProcessInfo.processInfo.processIdentifier

        for pid in pids where pid != myPid {
            // Check if this process is an orphan (PPID == 1, adopted by launchd)
            let psProc = Process()
            psProc.executableURL = URL(fileURLWithPath: "/bin/ps")
            psProc.arguments = ["-p", "\(pid)", "-o", "ppid="]
            let psPipe = Pipe()
            psProc.standardOutput = psPipe
            psProc.standardError = FileHandle.nullDevice

            do {
                try psProc.run()
            } catch {
                continue
            }
            psProc.waitUntilExit()

            let psData = psPipe.fileHandleForReading.readDataToEndOfFile()
            if let ppidStr = String(data: psData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let ppid = Int32(ppidStr), ppid == 1 {
                logger.notice("Killing orphaned guardian PID=\(pid)")
                kill(pid, SIGTERM)
            }
        }
    }

    /// Send raw JSON line to Guardian stdin. Serialized via writeQueue.
    public func send(line: Data) async {
        writeQueue.async { [weak self] in
            guard let pipe = self?.stdinPipe, self?.isAlive == true else { return }
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

        intentionalStop = false
        lastConfig = config

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

        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.process = proc

        // Monitor for unexpected termination
        proc.terminationHandler = { [weak self] _ in
            self?.handleTermination()
        }

        try proc.run()
        crashBreaker.recordStart()

        // Start background stdout reader
        let thread = Thread { [weak self] in
            self?.readStdoutLoop()
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
        intentionalStop = true
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    // MARK: - Private

    /// Handle unexpected Guardian process termination.
    /// Delegates crash tracking to CrashLoopBreaker which resets on stability.
    private func handleTermination() {
        // If stop() was called intentionally, don't auto-restart
        guard !intentionalStop else { return }

        let didTrip = crashBreaker.recordFailure()
        if didTrip { return }

        // Clear old pipes before restart
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

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
    private static func readStderrLoop(pipe: Pipe) {
        let logPath = "\(NSHomeDirectory())/.codo/guardian.log"

        // Open in append mode (create if missing)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logPath) {
            fileManager.createFile(atPath: logPath, contents: nil)
        }
        guard let logHandle = FileHandle(forWritingAtPath: logPath) else { return }
        logHandle.seekToEndOfFile()

        // Write startup marker
        let marker = "--- guardian stderr log started ---\n"
        logHandle.write(Data(marker.utf8))

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
                // Also write to log file with timestamp
                let logLine = "[\(dateFormatter.string(from: Date()))] \(line)\n"
                logHandle.write(Data(logLine.utf8))
            }
        }

        logHandle.closeFile()
    }
}
