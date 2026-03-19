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
        #expect(settings.baseURL == "https://api.openai.com/v1")
        #expect(settings.model == "gpt-4o-mini")
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

    @Test func readWriteContextLimit() {
        let defaults = freshDefaults()
        let settings = GuardianSettings(defaults: defaults)
        settings.contextLimit = 80_000
        #expect(settings.contextLimit == 80_000)
    }

    @Test func toEnvironment() {
        let defaults = freshDefaults()
        let settings = GuardianSettings(defaults: defaults)
        settings.baseURL = "https://custom.api.com/v1"
        settings.model = "gpt-4o"
        settings.contextLimit = 100_000

        let env = settings.toEnvironment(apiKey: "sk-test-key")
        #expect(env["CODO_API_KEY"] == "sk-test-key")
        #expect(env["CODO_BASE_URL"] == "https://custom.api.com/v1")
        #expect(env["CODO_MODEL"] == "gpt-4o")
        #expect(env["CODO_CONTEXT_LIMIT"] == "100000")
    }

    @Test func toEnvironmentWithDefaults() {
        let defaults = freshDefaults()
        let settings = GuardianSettings(defaults: defaults)
        let env = settings.toEnvironment(apiKey: "sk-key")
        #expect(env["CODO_BASE_URL"] == "https://api.openai.com/v1")
        #expect(env["CODO_MODEL"] == "gpt-4o-mini")
        #expect(env["CODO_CONTEXT_LIMIT"] == "160000")
    }
}
