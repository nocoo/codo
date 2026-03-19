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
  sound?: string;
  threadId?: string;
}

export type HookEventName =
  | "stop"
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
  apiKey: string;
  baseURL: string;
  model: string;
  contextLimit: number;
}
