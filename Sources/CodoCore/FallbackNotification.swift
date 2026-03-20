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
        let source = projectName(from: fields)

        switch hook {
        case "notification":
            let title = fields["title"] as? String ?? "Codo"
            let body = fields["message"] as? String
            return CodoMessage(title: title, body: body, source: source)

        case "stop":
            let body = truncate(
                fields["last_assistant_message"] as? String,
                maxLength: 100
            )
            return CodoMessage(title: "Task Complete", body: body, source: source)

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
            return CodoMessage(title: "\(toolName) result", body: body, source: source)

        case "post-tool-use-failure":
            let toolName = fields["tool_name"] as? String ?? "Tool"
            let body = truncate(
                fields["error"] as? String,
                maxLength: 100
            )
            return CodoMessage(title: "\(toolName) failed", body: body, source: source)

        case "session-start":
            let model = fields["model"] as? String
            return CodoMessage(title: "Session Started", body: model, source: source)

        case "session-end":
            return nil

        default:
            return nil
        }
    }

    /// Extract project name (last path component) from cwd field.
    private static func projectName(from fields: [String: Any]) -> String? {
        guard let cwd = fields["cwd"] as? String, !cwd.isEmpty else { return nil }
        return (cwd as NSString).lastPathComponent
    }

    /// Extract the Bash command string from a PostToolUse event.
    ///
    /// Claude Code hook payloads vary:
    /// - `command` may be a top-level string field
    /// - `tool_input` may be an object like `{ "command": "npm test" }`
    /// - `tool_input` may be a plain string (less common)
    private static func extractCommand(
        from fields: [String: Any]
    ) -> String? {
        // Prefer top-level command string
        if let command = fields["command"] as? String {
            return command
        }

        // Extract from tool_input object (real Claude hook format)
        if let toolInput = fields["tool_input"] as? [String: Any],
           let command = toolInput["command"] as? String {
            return command
        }

        // tool_input as plain string
        if let toolInput = fields["tool_input"] as? String {
            return toolInput
        }

        return nil
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
