import Foundation

/// Auto-discovered project from hook event cwd fields.
struct ProjectInfo: Identifiable, Codable, Equatable {
    let id: String  // cwd absolute path
    let name: String
    var customLogoPath: String?
    var lastSeen: Date

    init(
        cwd: String,
        customLogoPath: String? = nil,
        lastSeen: Date = Date()
    ) {
        self.id = cwd
        self.name = URL(fileURLWithPath: cwd).lastPathComponent
        self.customLogoPath = customLogoPath
        self.lastSeen = lastSeen
    }
}
