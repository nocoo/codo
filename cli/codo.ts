#!/usr/bin/env bun

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const VERSION = "0.1.0";
const SOCKET_PATH = join(homedir(), ".codo", "codo.sock");
const TIMEOUT_MS = 5000;

interface CodoMessage {
  title: string;
  body?: string;
  sound?: string;
}

interface CodoResponse {
  ok: boolean;
  error?: string;
}

function printUsage(): void {
  console.error(`Usage: codo <title> [body] [--silent]
       echo '{"title":"..."}' | codo

Options:
  --silent     Suppress notification sound
  --help       Show this help message
  --version    Show version`);
}

/**
 * Parse CLI args into a CodoMessage, or return null if no positional args.
 * Exported for testing.
 */
export function parseArgs(
  argv: string[],
): { message: CodoMessage } | { error: string } | null {
  const positional: string[] = [];
  let silent = false;

  for (const arg of argv) {
    if (arg === "--silent") {
      silent = true;
    } else if (!arg.startsWith("--")) {
      positional.push(arg);
    }
    // ignore unknown flags
  }

  if (positional.length === 0) return null;

  const title = positional[0];
  if (!title || title.trim().length === 0) {
    return { error: "title is required" };
  }

  const body = positional[1] || undefined;
  const sound = silent ? "none" : "default";

  return { message: { title, body, sound } };
}

/**
 * Parse stdin JSON into a CodoMessage.
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

  return { message };
}

/**
 * Send a message to the daemon via Unix Domain Socket.
 * Returns the parsed CodoResponse.
 */
async function sendToDaemon(
  message: CodoMessage,
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
          const payload = `${JSON.stringify(message)}\n`;
          socket.write(payload);
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
