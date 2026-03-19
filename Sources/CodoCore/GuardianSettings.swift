import Foundation

/// Pure data model for Guardian settings. No UI dependencies.
/// Reads/writes UserDefaults, but has no observation/binding support.
public struct GuardianSettings {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key: String {
        case guardianEnabled = "guardianEnabled"
        case provider = "guardianProvider"
        case baseURL = "guardianBaseURL"
        case model = "guardianModel"
        case sdkType = "guardianSdkType"
        case contextLimit = "guardianContextLimit"
    }

    // MARK: - Built-in Provider Registry

    /// SDK protocol type: "openai" or "anthropic".
    public enum SdkType: String, CaseIterable {
        case openai
        case anthropic
    }

    /// Built-in provider with preset base URL, SDK type, and models.
    public struct ProviderInfo {
        public let id: String
        public let label: String
        public let baseURL: String
        public let sdkType: SdkType
        public let models: [String]
        public let defaultModel: String
    }

    /// Built-in provider registry. Mirrors guardian/providers.ts.
    public static let builtinProviders: [ProviderInfo] = [
        ProviderInfo(
            id: "anthropic",
            label: "Anthropic",
            baseURL: "https://api.anthropic.com/v1",
            sdkType: .anthropic,
            models: ["claude-sonnet-4-20250514"],
            defaultModel: "claude-sonnet-4-20250514"
        ),
        ProviderInfo(
            id: "minimax",
            label: "MiniMax",
            baseURL: "https://api.minimaxi.com/anthropic/v1",
            sdkType: .anthropic,
            models: ["MiniMax-M2.7", "MiniMax-M2.5", "MiniMax-M2.1"],
            defaultModel: "MiniMax-M2.7"
        ),
        ProviderInfo(
            id: "glm",
            label: "GLM (Zhipu)",
            baseURL: "https://open.bigmodel.cn/api/anthropic/v1",
            sdkType: .anthropic,
            models: ["glm-5", "glm-4.7"],
            defaultModel: "glm-5"
        ),
        ProviderInfo(
            id: "aihubmix",
            label: "AIHubMix",
            baseURL: "https://aihubmix.com/v1",
            sdkType: .openai,
            models: ["gpt-4o-mini", "gpt-5-nano"],
            defaultModel: "gpt-4o-mini"
        )
    ]

    /// All provider IDs including "custom".
    public static let allProviderIDs: [String] =
        builtinProviders.map(\.id) + ["custom"]

    /// Look up a built-in provider by ID.
    public static func providerInfo(for id: String) -> ProviderInfo? {
        builtinProviders.first { $0.id == id }
    }

    // MARK: - Persisted Settings

    public var guardianEnabled: Bool {
        get { defaults.bool(forKey: Key.guardianEnabled.rawValue) }
        nonmutating set { defaults.set(newValue, forKey: Key.guardianEnabled.rawValue) }
    }

    /// Provider ID: "anthropic", "minimax", "glm", "aihubmix", or "custom".
    /// Default is "custom" for backward compatibility.
    public var provider: String {
        get { defaults.string(forKey: Key.provider.rawValue) ?? "custom" }
        nonmutating set { defaults.set(newValue, forKey: Key.provider.rawValue) }
    }

    public var baseURL: String {
        get { defaults.string(forKey: Key.baseURL.rawValue) ?? "https://api.openai.com/v1" }
        nonmutating set { defaults.set(newValue, forKey: Key.baseURL.rawValue) }
    }

    public var model: String {
        get { defaults.string(forKey: Key.model.rawValue) ?? "gpt-4o-mini" }
        nonmutating set { defaults.set(newValue, forKey: Key.model.rawValue) }
    }

    /// SDK type: "openai" or "anthropic". Default "openai" for backward compat.
    public var sdkType: String {
        get { defaults.string(forKey: Key.sdkType.rawValue) ?? "openai" }
        nonmutating set { defaults.set(newValue, forKey: Key.sdkType.rawValue) }
    }

    public var contextLimit: Int {
        get {
            let value = defaults.integer(forKey: Key.contextLimit.rawValue)
            return value > 0 ? value : 160_000
        }
        nonmutating set { defaults.set(newValue, forKey: Key.contextLimit.rawValue) }
    }

    /// Serialize to environment variables for Guardian child process.
    public func toEnvironment(apiKey: String) -> [String: String] {
        [
            "CODO_API_KEY": apiKey,
            "CODO_PROVIDER": provider,
            "CODO_BASE_URL": baseURL,
            "CODO_MODEL": model,
            "CODO_SDK_TYPE": sdkType,
            "CODO_CONTEXT_LIMIT": "\(contextLimit)"
        ]
    }
}
