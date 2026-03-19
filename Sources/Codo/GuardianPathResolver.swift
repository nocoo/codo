import Foundation

/// Resolves the guardian/main.ts entry point from bundle or dev layout.
enum GuardianPathResolver {
    static func resolve() -> String? {
        // 1. Bundle Resources/guardian/main.ts
        if let bundlePath = Bundle.main.resourcePath {
            let path = "\(bundlePath)/guardian/main.ts"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        // 2. Development: derive from executable path
        if let execURL = Bundle.main.executableURL {
            let projectDir = execURL
                .deletingLastPathComponent() // MacOS
                .deletingLastPathComponent() // Contents
                .deletingLastPathComponent() // Codo.app
                .deletingLastPathComponent() // release
                .deletingLastPathComponent() // .build
            let devPath = projectDir
                .appendingPathComponent("guardian")
                .appendingPathComponent("main.ts").path
            if FileManager.default.fileExists(atPath: devPath) { return devPath }
        }
        return nil
    }
}
