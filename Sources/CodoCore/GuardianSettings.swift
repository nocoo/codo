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
        case baseURL = "guardianBaseURL"
        case model = "guardianModel"
        case contextLimit = "guardianContextLimit"
    }

    public var guardianEnabled: Bool {
        get { defaults.bool(forKey: Key.guardianEnabled.rawValue) }
        nonmutating set { defaults.set(newValue, forKey: Key.guardianEnabled.rawValue) }
    }

    public var baseURL: String {
        get { defaults.string(forKey: Key.baseURL.rawValue) ?? "https://api.openai.com/v1" }
        nonmutating set { defaults.set(newValue, forKey: Key.baseURL.rawValue) }
    }

    public var model: String {
        get { defaults.string(forKey: Key.model.rawValue) ?? "gpt-4o-mini" }
        nonmutating set { defaults.set(newValue, forKey: Key.model.rawValue) }
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
            "CODO_BASE_URL": baseURL,
            "CODO_MODEL": model,
            "CODO_CONTEXT_LIMIT": "\(contextLimit)"
        ]
    }
}
