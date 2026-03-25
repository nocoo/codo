import Foundation
import os

private let logger = Logger(subsystem: "ai.hexly.codo.04", category: "guardian")

// MARK: - Static Utility Methods

extension GuardianProcess {
    /// Resolve the bun executable path by checking common locations
    /// and falling back to `which bun`.
    public static func resolveBunPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
            "\(NSHomeDirectory())/.bun/bin/bun"
        ]

        let fileManager = FileManager.default
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return path
        }

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
    /// Filters to PPID == 1 (adopted by launchd = true orphans).
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
}
