import AppKit
import CodoCore

@main
struct CodoApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Prevent macOS from auto-terminating this background daemon
        ProcessInfo.processInfo.disableAutomaticTermination("Codo daemon must stay alive")
        ProcessInfo.processInfo.disableSuddenTermination()
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
