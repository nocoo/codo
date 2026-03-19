import Combine
import CodoCore
import Foundation

/// ViewModel for settings window. Wraps GuardianSettings + KeychainService
/// with @Published properties for two-way binding.
/// Lives in app target to keep CodoCore free of Combine imports.
final class SettingsViewModel: ObservableObject {
    @Published var guardianEnabled: Bool
    @Published var provider: String
    @Published var baseURL: String
    @Published var model: String
    @Published var sdkType: String
    @Published var contextLimit: Int
    @Published var apiKey: String

    private let settings: GuardianSettings

    init(settings: GuardianSettings = GuardianSettings()) {
        self.settings = settings
        self.guardianEnabled = settings.guardianEnabled
        self.provider = settings.provider
        self.baseURL = settings.baseURL
        self.model = settings.model
        self.sdkType = settings.sdkType
        self.contextLimit = settings.contextLimit
        self.apiKey = KeychainService.readAPIKey() ?? ""
    }

    /// Whether the current provider is "custom" (show base URL / SDK type fields).
    var isCustomProvider: Bool { provider == "custom" }

    /// Look up the current built-in provider info (nil for custom).
    var currentProviderInfo: GuardianSettings.ProviderInfo? {
        GuardianSettings.providerInfo(for: provider)
    }

    /// Apply defaults from a built-in provider (base URL, model, sdkType).
    func applyProviderDefaults() {
        if let info = currentProviderInfo {
            baseURL = info.baseURL
            model = info.defaultModel
            sdkType = info.sdkType.rawValue
        }
    }

    /// Persist all fields to UserDefaults + Keychain.
    func save() throws {
        settings.guardianEnabled = guardianEnabled
        settings.provider = provider
        settings.baseURL = baseURL
        settings.model = model
        settings.sdkType = sdkType
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
        provider = settings.provider
        baseURL = settings.baseURL
        model = settings.model
        sdkType = settings.sdkType
        contextLimit = settings.contextLimit
        apiKey = KeychainService.readAPIKey() ?? ""
    }
}
