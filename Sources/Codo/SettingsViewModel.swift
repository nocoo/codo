import Combine
import CodoCore
import Foundation

/// ViewModel for settings window. Wraps GuardianSettings + KeychainService
/// with @Published properties for two-way binding.
/// Lives in app target to keep CodoCore free of Combine imports.
final class SettingsViewModel: ObservableObject {
    @Published var guardianEnabled: Bool
    @Published var baseURL: String
    @Published var model: String
    @Published var contextLimit: Int
    @Published var apiKey: String

    private let settings: GuardianSettings

    init(settings: GuardianSettings = GuardianSettings()) {
        self.settings = settings
        self.guardianEnabled = settings.guardianEnabled
        self.baseURL = settings.baseURL
        self.model = settings.model
        self.contextLimit = settings.contextLimit
        self.apiKey = KeychainService.readAPIKey() ?? ""
    }

    /// Persist all fields to UserDefaults + Keychain.
    func save() throws {
        settings.guardianEnabled = guardianEnabled
        settings.baseURL = baseURL
        settings.model = model
        settings.contextLimit = contextLimit

        if !apiKey.isEmpty {
            try KeychainService.writeAPIKey(apiKey)
        } else {
            try KeychainService.deleteAPIKey()
        }
    }

    /// Reload from persisted state (discard unsaved changes).
    func reload() {
        guardianEnabled = settings.guardianEnabled
        baseURL = settings.baseURL
        model = settings.model
        contextLimit = settings.contextLimit
        apiKey = KeychainService.readAPIKey() ?? ""
    }
}
