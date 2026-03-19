import Foundation

/// Builds a fallback CodoMessage from raw hook event JSON.
/// Used when Guardian is OFF or unavailable.
/// Returns nil to suppress the notification (e.g., session-end).
public enum FallbackNotification {
    public static func build(
        from rawJSON: Data
    ) -> CodoMessage? {
        guard let obj = try? JSONSerialization.jsonObject(
            with: rawJSON
        ) as? [String: Any],
              let hook = obj["_hook"] as? String else {
            return nil
        }
        return buildMessage(hook: hook, fields: obj)
    }

    // MARK: - Private

    private static func buildMessage(
        hook: String,
        fields: [String: Any]
    ) -> CodoMessage? {
        switch hook {
        case "notification":
            let title = fields["title"] as? String ?? "Codo"
            let body = fields["message"] as? String
            return CodoMessage(title: title, body: body)

        case "stop":
            let body = truncate(
                fields["last_assistant_message"] as? String,
                maxLength: 100
            )
            return CodoMessage(title: "Task Complete", body: body)

        case "post-tool-use":
            guard let command = extractCommand(from: fields),
                  isImportantCommand(command) else {
                return nil
            }
            let toolName = fields["tool_name"] as? String ?? "Tool"
            let body = truncate(
                fields["tool_response"] as? String,
                maxLength: 100
            )
            return CodoMessage(title: "\(toolName) result", body: body)

        case "post-tool-use-failure":
            let toolName = fields["tool_name"] as? String ?? "Tool"
            let body = truncate(
                fields["error"] as? String,
                maxLength: 100
            )
            return CodoMessage(title: "\(toolName) failed", body: body)

        case "session-start":
            let model = fields["model"] as? String
            return CodoMessage(title: "Session Started", body: model)

        case "session-end":
            return nil

        default:
            return nil
        }
    }

    private static func extractCommand(
        from fields: [String: Any]
    ) -> String? {
        fields["command"] as? String
            ?? fields["tool_input"] as? String
    }

    /// Check if a Bash command is "important" (test/build/git/deploy).
    static func isImportantCommand(_ command: String) -> Bool {
        let patterns = [
            "test", "build", "compile", "deploy",
            "git commit", "git push", "git merge",
            "npm ", "bun test", "swift test", "swift build",
            "cargo test", "cargo build", "make"
        ]
        let lower = command.lowercased()
        return patterns.contains { lower.contains($0) }
    }

    /// Truncate a string to maxLength, appending "..." if truncated.
    static func truncate(
        _ string: String?,
        maxLength: Int
    ) -> String? {
        guard let string, !string.isEmpty else { return nil }
        if string.count <= maxLength { return string }
        return String(string.prefix(maxLength)) + "..."
    }
}
