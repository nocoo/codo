import Foundation

/// Reads and writes the API key from ~/.codo/api-key file.
public enum KeychainService {
    private static var keyFilePath: String {
        "\(NSHomeDirectory())/.codo/api-key"
    }

    public static func readAPIKey() -> String? {
        guard let data = FileManager.default.contents(atPath: keyFilePath),
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    public static func writeAPIKey(_ key: String) throws {
        let dir = (keyFilePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        guard let data = key.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        FileManager.default.createFile(atPath: keyFilePath, contents: data, attributes: [
            .posixPermissions: 0o600
        ])
    }

    public static func deleteAPIKey() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: keyFilePath) else { return }
        try manager.removeItem(atPath: keyFilePath)
    }
}

public enum KeychainError: Error, CustomStringConvertible {
    case encodingFailed
    case writeFailed(status: Int)
    case deleteFailed(status: Int)

    public var description: String {
        switch self {
        case .encodingFailed:
            return "api-key: failed to encode"
        case .writeFailed(let status):
            return "api-key: write failed (status \(status))"
        case .deleteFailed(let status):
            return "api-key: delete failed (status \(status))"
        }
    }
}
