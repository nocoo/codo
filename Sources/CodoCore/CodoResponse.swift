import Foundation

/// Response from daemon to CLI.
public struct CodoResponse: Codable, Sendable {
    public let ok: Bool
    public let error: String?

    public var isOk: Bool { ok }
    public var errorMessage: String? { error }

    /// Success response.
    public static let ok = CodoResponse(ok: true, error: nil)

    /// Error response with message.
    public static func error(_ message: String) -> CodoResponse {
        CodoResponse(ok: false, error: message)
    }
}
