import AppKit
import CodoCore

@main
struct CodoApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // no Dock icon
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
