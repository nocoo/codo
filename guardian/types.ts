// Event stream types (bidirectional line-delimited JSON)
//
// Daemon → Guardian (stdin): raw hook JSON (with _hook field) or CodoMessage
// Guardian → Daemon (stdout): GuardianAction JSON line

export interface GuardianAction {
  action: "send" | "suppress";
  notification?: NotificationPayload;
  reason?: string;
}

export interface GuardianResult {
  action: "send" | "suppress";
  notification?: NotificationPayload;
  reason?: string;
}

export interface NotificationPayload {
  title: string;
  body?: string;
  subtitle?: string;
  source?: string;       // project name (basename of cwd)
  sound?: string;
  threadId?: string;
}

export type HookEventName =
  | "stop"
  | "subagent-stop"
  | "notification"
  | "post-tool-use"
  | "post-tool-use-failure"
  | "session-start"
  | "session-end";

export interface HookEvent {
  _hook: HookEventName;
  session_id: string;
  cwd?: string;
  transcript_path?: string;
  hook_event_name: string;
  [key: string]: unknown;
}

export interface GuardianConfig {
  provider: string;
  apiKey: string;
  baseURL: string;
  model: string;
  sdkType: string;
  contextLimit: number;
}

/**
 * Extract the Bash command string from a PostToolUse event.
 *
 * Claude Code hook payloads vary:
 * - `tool_input` may be an object like `{ command: "npm test" }` or a string
 * - `command` may be a top-level string field (our test fixtures use this)
 *
 * This function normalizes both shapes to a plain command string.
 */
export function extractCommand(event: HookEvent): string {
  // Prefer top-level `command` (used in tests and some hook versions)
  if (typeof event.command === "string") return event.command;

  // Extract from tool_input object
  const input = event.tool_input;
  if (input && typeof input === "object" && !Array.isArray(input)) {
    const obj = input as Record<string, unknown>;
    if (typeof obj.command === "string") return obj.command;
  }

  // tool_input as plain string (unlikely but safe)
  if (typeof input === "string") return input;

  return "";
}
