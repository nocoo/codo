#!/usr/bin/env bun

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const VERSION = "0.2.0";
const SOCKET_PATH = join(homedir(), ".codo", "codo.sock");
const TIMEOUT_MS = 5000;

export interface CodoMessage {
  title: string;
  body?: string;
  subtitle?: string;
  sound?: string;
  threadId?: string;
}

interface CodoResponse {
  ok: boolean;
  error?: string;
}

// --- Hook Types ---

export const VALID_HOOK_TYPES = new Set([
  "stop",
  "notification",
  "post-tool-use",
  "post-tool-use-failure",
  "session-start",
  "session-end",
]);

// --- Templates ---

interface TemplateDefaults {
  subtitle: string;
  sound: "default" | "none";
}

export const TEMPLATES: Record<string, TemplateDefaults> = {
  success: { subtitle: "✅ Success", sound: "default" },
  error: { subtitle: "❌ Error", sound: "default" },
  warning: { subtitle: "⚠️ Warning", sound: "default" },
  info: { subtitle: "ℹ️ Info", sound: "none" },
  progress: { subtitle: "🔄 In Progress", sound: "none" },
  question: { subtitle: "❓ Action Needed", sound: "default" },
  deploy: { subtitle: "🚀 Deploy", sound: "default" },
  review: { subtitle: "👀 Review", sound: "default" },
};

function printTemplateList(): void {
  console.error("Available templates:\n");
  console.error("  Name        Subtitle            Sound");
  console.error("  ----------  ------------------  -------");
  for (const [name, t] of Object.entries(TEMPLATES)) {
    const padName = name.padEnd(10);
    const padSub = t.subtitle.padEnd(18);
    console.error(`  ${padName}  ${padSub}  ${t.sound}`);
  }
}

// --- Parsing ---

function printUsage(): void {
  console.error(`Usage: codo <title> [body] [--template <name>] [--subtitle <text>] [--thread <id>] [--silent]
       echo '{"title":"..."}' | codo
       echo '{"session_id":"..."}' | codo --hook stop

Options:
  --template <name>   Apply a notification template (use --template list to see all)
  --subtitle <text>   Set notification subtitle
  --thread <id>       Set thread ID for notification grouping
  --hook <type>       Forward raw stdin JSON as hook event (stop, notification, etc.)
  --silent            Suppress notification sound
  --help              Show this help message
  --version           Show version`);
}

/** Trim a string value; return undefined if empty/whitespace. */
function normalize(value: string | undefined): string | undefined {
  if (value === undefined) return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

/**
 * Apply template defaults to a message. Explicit values win over template.
 * Exported for testing.
 */
export function applyTemplate(
  message: CodoMessage,
  templateName: string,
): { message: CodoMessage } | { error: string } {
  const tmpl = TEMPLATES[templateName];
  if (!tmpl) {
    return { error: `unknown template: ${templateName}` };
  }

  return {
    message: {
      ...message,
      subtitle: message.subtitle ?? tmpl.subtitle,
      sound: message.sound ?? tmpl.sound,
    },
  };
}

/**
 * Parse CLI args into a CodoMessage, or return null if no positional args.
 * Exported for testing.
 */
export function parseArgs(
  argv: string[],
): { message: CodoMessage; template?: string } | { error: string } | null {
  const positional: string[] = [];
  let silent = false;
  let template: string | undefined;
  let subtitle: string | undefined;
  let threadId: string | undefined;

  const valueFlagNames = new Set(["--template", "--subtitle", "--thread"]);

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--silent") {
      silent = true;
    } else if (valueFlagNames.has(arg)) {
      const next = argv[i + 1];
      if (next === undefined || next.startsWith("--")) {
        return { error: `${arg} requires a value` };
      }
      i++; // consume next token
      if (arg === "--template") template = next;
      else if (arg === "--subtitle") subtitle = next;
      else if (arg === "--thread") threadId = next;
    } else if (arg.startsWith("--")) {
      // ignore unknown flags
    } else {
      positional.push(arg);
    }
  }

  if (positional.length === 0 && !template && !subtitle && !threadId) {
    return null;
  }

  const title = positional[0];
  if (!title || title.trim().length === 0) {
    return { error: "title is required" };
  }

  const body = positional[1] || undefined;
  const sound = silent ? "none" : undefined;

  const message: CodoMessage = { title, body };
  if (normalize(subtitle) !== undefined) message.subtitle = normalize(subtitle);
  if (sound !== undefined) message.sound = sound;
  if (normalize(threadId) !== undefined) message.threadId = normalize(threadId);

  if (template !== undefined) {
    const applied = applyTemplate(message, template);
    if ("error" in applied) return applied;
    return { message: applied.message, template };
  }

  // No template — apply default sound if not silent
  if (message.sound === undefined) message.sound = "default";

  return { message, template };
}

/**
 * Parse stdin JSON into a CodoMessage.
 * Only wire-format fields accepted; "template" key is ignored.
 * Exported for testing.
 */
export function parseStdin(
  input: string,
): { message: CodoMessage } | { error: string } {
  const trimmed = input.trim();
  if (trimmed.length === 0) {
    return { error: "empty input" };
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return { error: "invalid json" };
  }

  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return { error: "invalid json" };
  }

  const obj = parsed as Record<string, unknown>;
  if (typeof obj.title !== "string" || obj.title.trim().length === 0) {
    return { error: "title is required" };
  }

  const message: CodoMessage = { title: obj.title };
  if (typeof obj.body === "string") {
    message.body = obj.body;
  }
  if (typeof obj.sound === "string") {
    message.sound = obj.sound;
  }
  // Normalize subtitle and threadId — empty/whitespace → omit
  if (typeof obj.subtitle === "string") {
    const sub = normalize(obj.subtitle);
    if (sub !== undefined) message.subtitle = sub;
  }
  if (typeof obj.threadId === "string") {
    const tid = normalize(obj.threadId);
    if (tid !== undefined) message.threadId = tid;
  }

  return { message };
}

/**
 * Parse hook event from stdin JSON. Injects `_hook` field.
 * Returns the raw object to send to daemon (not a CodoMessage).
 * Exported for testing.
 */
export function parseHook(
  hookType: string,
  stdinJSON: string,
): { payload: Record<string, unknown> } | { error: string } {
  if (!VALID_HOOK_TYPES.has(hookType)) {
    return { error: `unknown hook type: ${hookType}` };
  }

  const trimmed = stdinJSON.trim();
  if (trimmed.length === 0) {
    return { error: "empty input" };
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return { error: "invalid json" };
  }

  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return { error: "invalid json" };
  }

  const obj = parsed as Record<string, unknown>;
  return { payload: { ...obj, _hook: hookType } };
}

/**
 * Send a JSON payload to the daemon via Unix Domain Socket.
 * Returns the parsed CodoResponse.
 */
async function sendToDaemon(
  payload: Record<string, unknown>,
  socketPath: string = SOCKET_PATH,
): Promise<CodoResponse> {
  if (!existsSync(socketPath)) {
    throw new DaemonError("codo daemon not running", 2);
  }

  return new Promise<CodoResponse>((resolve, reject) => {
    const timer = setTimeout(() => {
      socket.end();
      reject(new DaemonError("timeout", 3));
    }, TIMEOUT_MS);

    let data = "";
    const socket = Bun.connect({
      unix: socketPath,
      socket: {
        data(_socket, chunk) {
          data += chunk.toString();
          if (data.includes("\n")) {
            clearTimeout(timer);
            try {
              const response = JSON.parse(data.trim()) as CodoResponse;
              resolve(response);
            } catch {
              reject(
                new DaemonError("unexpected response from daemon", 3),
              );
            }
            _socket.end();
          }
        },
        open(socket) {
          const data = `${JSON.stringify(payload)}\n`;
          socket.write(data);
          socket.flush();
        },
        error(_socket, err) {
          clearTimeout(timer);
          reject(
            new DaemonError(
              `cannot connect to codo daemon: ${err.message}`,
              3,
            ),
          );
        },
        close() {
          clearTimeout(timer);
          if (data.trim().length === 0) {
            reject(new DaemonError("unexpected response from daemon", 3));
          }
        },
        connectError(_socket, err) {
          clearTimeout(timer);
          reject(
            new DaemonError(
              `cannot connect to codo daemon: ${err.message}`,
              3,
            ),
          );
        },
      },
    });
  });
}

class DaemonError extends Error {
  exitCode: number;
  constructor(message: string, exitCode: number) {
    super(message);
    this.exitCode = exitCode;
  }
}

/** Lightweight diagnostic log for --hook mode. Writes to stderr (captured by hooks.log). */
function hookLog(level: string, msg: string, data?: Record<string, unknown>): void {
  const parts = [`[codo-cli] ${level} ${msg}`];
  if (data) {
    for (const [k, v] of Object.entries(data)) {
      parts.push(`${k}=${typeof v === "string" ? v : JSON.stringify(v)}`);
    }
  }
  process.stderr.write(`${parts.join(" ")}\n`);
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);

  if (args.includes("--help")) {
    printUsage();
    process.exit(0);
  }

  if (args.includes("--version")) {
    console.error(`codo ${VERSION}`);
    process.exit(0);
  }

  // Handle --template list before normal parsing
  const templateIdx = args.indexOf("--template");
  if (templateIdx !== -1 && args[templateIdx + 1] === "list") {
    printTemplateList();
    process.exit(0);
  }

  // Handle --hook <type>: forward raw stdin JSON with _hook discriminator
  const hookIdx = args.indexOf("--hook");
  if (hookIdx !== -1) {
    const hookType = args[hookIdx + 1];
    if (hookType === undefined || hookType.startsWith("--")) {
      console.error("--hook requires a value");
      process.exit(1);
    }

    // --hook conflicts with positional args
    const positional = args.filter(
      (a, i) => !a.startsWith("--") && i !== hookIdx + 1,
    );
    if (positional.length > 0) {
      console.error("--hook cannot be used with positional args");
      process.exit(1);
    }

    // Read stdin
    const stdinText = await Bun.stdin.text();
    const hookResult = parseHook(hookType, stdinText);
    if ("error" in hookResult) {
      hookLog("ERROR", "parse failed", { hook: hookType, error: hookResult.error });
      console.error(hookResult.error);
      process.exit(1);
    }

    hookLog("DEBUG", "parsed", {
      hook: hookType,
      payload_bytes: String(stdinText.length),
    });

    try {
      hookLog("DEBUG", "connecting", { socket: SOCKET_PATH });
      const response = await sendToDaemon(hookResult.payload);
      if (!response.ok) {
        hookLog("ERROR", "daemon rejected", { error: response.error ?? "unknown" });
        console.error(response.error || "unknown error");
        process.exit(1);
      }
      hookLog("DEBUG", "sent ok", { hook: hookType });
      process.exit(0);
    } catch (err) {
      if (err instanceof DaemonError) {
        hookLog("ERROR", "daemon error", { error: err.message, exit: String(err.exitCode) });
        console.error(err.message);
        process.exit(err.exitCode);
      }
      hookLog("ERROR", "unexpected", { error: err instanceof Error ? err.message : "unknown" });
      console.error("unexpected error");
      process.exit(3);
    }
  }

  // Args always win over stdin
  const argsResult = parseArgs(args);

  let message: CodoMessage;

  if (argsResult) {
    if ("error" in argsResult) {
      console.error(argsResult.error);
      process.exit(1);
    }
    message = argsResult.message;
  } else if (!Bun.stdin.isTTY) {
    // Read from stdin
    const stdinText = await Bun.stdin.text();
    const stdinResult = parseStdin(stdinText);
    if ("error" in stdinResult) {
      console.error(stdinResult.error);
      process.exit(1);
    }
    message = stdinResult.message;
  } else {
    // No args, no stdin
    printUsage();
    process.exit(1);
  }

  try {
    const response = await sendToDaemon(message);
    if (!response.ok) {
      console.error(response.error || "unknown error");
      process.exit(1);
    }
    // Success: exit 0, no stdout
    process.exit(0);
  } catch (err) {
    if (err instanceof DaemonError) {
      console.error(err.message);
      process.exit(err.exitCode);
    }
    console.error("unexpected error");
    process.exit(3);
  }
}

// Only run main when executed directly, not when imported
if (import.meta.main) {
  main();
}
