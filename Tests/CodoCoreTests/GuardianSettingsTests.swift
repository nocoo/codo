import Foundation
import Testing

@testable import CodoCore

@Suite("GuardianSettings")
struct GuardianSettingsTests {
    /// Create a fresh UserDefaults suite for each test to avoid cross-contamination.
    private func freshDefaults() -> UserDefaults {
        let suiteName = "codo.test.\(UUID().uuidString.prefix(8))"
        return UserDefaults(suiteName: suiteName)!
    }

    @Test func defaultValues() {
        let defaults = freshDefaults()
        let settings = GuardianSettings(defaults: defaults)
        #expect(settings.guardianEnabled == false)
        #expect(settings.provider == "custom")
        #expect(settings.baseURL == "https://api.openai.com/v1")
        #expect(settings.model == "gpt-4o-mini")
        #expect(settings.sdkType == "openai")
        #expect(settings.contextLimit == 160_000)
    }

    @Test func readWriteGuardianEnabled() {
        let defaults = freshDefaults()
        let settings = GuardianSettings(defaults: defaults)
        #expect(settings.guardianEnabled == false)
        settings.guardianEnabled = true
        #expect(settings.guardianEnabled == true)
        settings.guardianEnabled = false
        #expect(settings.guardianEnabled == false)
    }

    @Test func readWriteProvider() {
        let defaults = freshDefaults()
        let settings = GuardianSettings(defaults: defaults)
        #expect(settings.provider == "custom")
        settings.provider = "anthropic"
        #expect(settings.provider == "anthropic")
    }

    @Test func readWriteBaseURL() {
        let defaults = freshDefaults()
        let settings = GuardianSettings(defaults: defaults)
        settings.baseURL = "https://custom.api.com/v1"
        #expect(settings.baseURL == "https://custom.api.com/v1")
    }

    @Test func readWriteModel() {
        let defaults = freshDefaults()
        let settings = GuardianSettings(defaults: defaults)
        settings.model = "gpt-4o"
        #expect(settings.model == "gpt-4o")
    }

    @Test func readWriteSdkType() {
        let defaults = freshDefaults()
        let settings = GuardianSettings(defaults: defaults)
        #expect(settings.sdkType == "openai")
        settings.sdkType = "anthropic"
        #expect(settings.sdkType == "anthropic")
    }

    @Test func readWriteContextLimit() {
        let defaults = freshDefaults()
        let settings = GuardianSettings(defaults: defaults)
        settings.contextLimit = 80_000
        #expect(settings.contextLimit == 80_000)
    }

    @Test func toEnvironment() {
        let defaults = freshDefaults()
        let settings = GuardianSettings(defaults: defaults)
        settings.provider = "anthropic"
        settings.baseURL = "https://api.anthropic.com/v1"
        settings.model = "claude-sonnet-4-20250514"
        settings.sdkType = "anthropic"
        settings.contextLimit = 100_000

        let env = settings.toEnvironment(apiKey: "sk-test-key")
        #expect(env["CODO_API_KEY"] == "sk-test-key")
        #expect(env["CODO_PROVIDER"] == "anthropic")
        #expect(env["CODO_BASE_URL"] == "https://api.anthropic.com/v1")
        #expect(env["CODO_MODEL"] == "claude-sonnet-4-20250514")
        #expect(env["CODO_SDK_TYPE"] == "anthropic")
        #expect(env["CODO_CONTEXT_LIMIT"] == "100000")
    }

    @Test func toEnvironmentWithDefaults() {
        let defaults = freshDefaults()
        let settings = GuardianSettings(defaults: defaults)
        let env = settings.toEnvironment(apiKey: "sk-key")
        #expect(env["CODO_PROVIDER"] == "custom")
        #expect(env["CODO_BASE_URL"] == "https://api.openai.com/v1")
        #expect(env["CODO_MODEL"] == "gpt-4o-mini")
        #expect(env["CODO_SDK_TYPE"] == "openai")
        #expect(env["CODO_CONTEXT_LIMIT"] == "160000")
    }

    // MARK: - Provider Registry

    @Test func builtinProvidersHaveFourEntries() {
        #expect(GuardianSettings.builtinProviders.count == 4)
    }

    @Test func allProviderIDsIncludesCustom() {
        let ids = GuardianSettings.allProviderIDs
        #expect(ids.contains("anthropic"))
        #expect(ids.contains("minimax"))
        #expect(ids.contains("glm"))
        #expect(ids.contains("aihubmix"))
        #expect(ids.contains("custom"))
        #expect(ids.count == 5)
    }

    @Test func providerInfoForBuiltin() {
        let info = GuardianSettings.providerInfo(for: "anthropic")
        #expect(info != nil)
        #expect(info?.sdkType == .anthropic)
        #expect(info?.baseURL == "https://api.anthropic.com")
        #expect(info?.defaultModel == "claude-sonnet-4-20250514")
    }

    @Test func providerInfoForCustomReturnsNil() {
        #expect(GuardianSettings.providerInfo(for: "custom") == nil)
    }

    @Test func providerInfoForUnknownReturnsNil() {
        #expect(GuardianSettings.providerInfo(for: "nonexistent") == nil)
    }

    @Test func eachBuiltinHasConsistentDefaults() {
        for info in GuardianSettings.builtinProviders {
            #expect(!info.id.isEmpty)
            #expect(!info.label.isEmpty)
            #expect(info.baseURL.hasPrefix("https://"))
            #expect(!info.models.isEmpty)
            #expect(info.models.contains(info.defaultModel))
        }
    }
}
