import Foundation

/// Resolves the guardian/main.ts entry point from bundle or dev layout.
enum GuardianPathResolver {
    static func resolve() -> String? {
        // 1. Bundle Resources/guardian/main.ts (production)
        if let bundlePath = Bundle.main.resourcePath {
            let path = "\(bundlePath)/guardian/main.ts"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        // 2. Development: walk up from executable until we find guardian/main.ts.
        //    Handles both .build/release/Codo.app and
        //    .build/<triple>/release/Codo.app layouts.
        if let execURL = Bundle.main.executableURL {
            var dir = execURL.deletingLastPathComponent()
            for _ in 0..<8 {
                let candidate = dir
                    .appendingPathComponent("guardian")
                    .appendingPathComponent("main.ts")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate.path
                }
                let parent = dir.deletingLastPathComponent()
                if parent == dir { break }
                dir = parent
            }
        }
        return nil
    }
}
