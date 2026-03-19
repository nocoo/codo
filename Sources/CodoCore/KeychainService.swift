import Foundation
import Security

/// Reads and writes the API key from macOS Keychain.
public enum KeychainService {
    private static let service = "ai.hexly.codo.01"
    private static let account = "guardian-api-key"

    public static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    public static func writeAPIKey(_ key: String) throws {
        // Delete existing key first
        try? deleteAPIKey()

        guard let data = key.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.writeFailed(status: status)
        }
    }

    public static func deleteAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: status)
        }
    }
}

public enum KeychainError: Error, CustomStringConvertible {
    case encodingFailed
    case writeFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)

    public var description: String {
        switch self {
        case .encodingFailed:
            return "keychain: failed to encode API key"
        case .writeFailed(let status):
            return "keychain: write failed (status \(status))"
        case .deleteFailed(let status):
            return "keychain: delete failed (status \(status))"
        }
    }
}
