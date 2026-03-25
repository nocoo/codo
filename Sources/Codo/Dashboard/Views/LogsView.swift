import SwiftUI

/// Displays log files with live tailing.
struct LogsView: View {
    @State private var selectedLog: LogFile = .guardian
    @State private var logContent = "Loading..."
    @State private var fileMonitor: DispatchSourceFileSystemObject?

    private enum LogFile: String, CaseIterable, Identifiable {
        case guardian = "guardian.log"
        case hooks = "hooks.log"
        var id: String { rawValue }
        var path: String { "\(NSHomeDirectory())/.codo/\(rawValue)" }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("Log File", selection: $selectedLog) {
                ForEach(LogFile.allCases) { log in
                    Text(log.rawValue).tag(log)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            // Log content
            ScrollViewReader { proxy in
                ScrollView {
                    Text(logContent)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .id("logBottom")
                }
                .onChange(of: logContent) { _, _ in
                    proxy.scrollTo("logBottom", anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startMonitoring() }
        .onDisappear { stopMonitoring() }
        .onChange(of: selectedLog) { _, _ in
            startMonitoring()
        }
    }

    private func startMonitoring() {
        stopMonitoring()
        loadLogFile()

        let path = selectedLog.path
        guard let fileDescriptor = openFileDescriptor(at: path) else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [self] in
            let event = source.data
            if event.contains(.rename) || event.contains(.delete) {
                // File was rotated/deleted — reopen after new file is created
                stopMonitoring()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    startMonitoring()
                }
            } else {
                loadLogFile()
            }
        }
        source.setCancelHandler {
            close(fileDescriptor)
        }
        source.resume()
        fileMonitor = source
    }

    private func stopMonitoring() {
        fileMonitor?.cancel()
        fileMonitor = nil
    }

    private func loadLogFile() {
        let path = selectedLog.path
        guard FileManager.default.fileExists(atPath: path),
              let handle = FileHandle(forReadingAtPath: path) else {
            logContent = "(no log file found)"
            return
        }
        defer { handle.closeFile() }

        // Read last 32KB
        let maxBytes: UInt64 = 32_768
        let fileSize = handle.seekToEndOfFile()
        let offset = fileSize > maxBytes ? fileSize - maxBytes : 0
        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        logContent = String(data: data, encoding: .utf8)
            ?? "(binary content)"
    }

    private func openFileDescriptor(at path: String) -> Int32? {
        let descriptor = open(path, O_EVTONLY)
        return descriptor >= 0 ? descriptor : nil
    }
}
