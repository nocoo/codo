/**
 * Structured logging for the Guardian process.
 *
 * All output goes to stderr (captured by the Swift host into ~/.codo/guardian.log).
 *
 * Modes:
 *   CODO_DEBUG=1  → JSON-per-line (machine-readable, pipe to `jq`)
 *   otherwise     → human-readable single-line format
 *
 * Usage:
 *   import { createLogger } from "./logger";
 *   const log = createLogger("classifier");
 *   log.debug("classify", "matched pattern", { cmd: "bun test", tier: "important" });
 */

export type LogLevel = "DEBUG" | "INFO" | "WARN" | "ERROR";

const LEVEL_ORDER: Record<LogLevel, number> = {
  DEBUG: 0,
  INFO: 1,
  WARN: 2,
  ERROR: 3,
};

export interface LogEntry {
  ts: string;
  level: LogLevel;
  component: string;
  op: string;
  sid?: string;
  ms?: number;
  msg: string;
  data?: Record<string, unknown>;
}

export interface Logger {
  debug(op: string, msg: string, data?: Record<string, unknown>): void;
  info(op: string, msg: string, data?: Record<string, unknown>): void;
  warn(op: string, msg: string, data?: Record<string, unknown>): void;
  error(op: string, msg: string, data?: Record<string, unknown>): void;
  /** Bind a session ID to include in all subsequent log entries. */
  withSession(sid: string): Logger;
}

const isDebugMode = () => process.env.CODO_DEBUG === "1";

/** Minimum level: DEBUG when CODO_DEBUG=1, INFO otherwise. */
const minLevel = (): LogLevel => (isDebugMode() ? "DEBUG" : "INFO");

function shouldLog(level: LogLevel): boolean {
  return LEVEL_ORDER[level] >= LEVEL_ORDER[minLevel()];
}

/** Truncate session ID to first 8 characters for readability. */
function shortSid(sid: string | undefined): string | undefined {
  if (!sid) return undefined;
  return sid.length > 8 ? sid.slice(0, 8) : sid;
}

function formatJson(entry: LogEntry): string {
  return JSON.stringify(entry);
}

function formatHuman(entry: LogEntry): string {
  const parts: string[] = [
    `guardian:${entry.component}`,
    entry.level.padEnd(5),
    `[${entry.op}]`,
    entry.msg,
  ];
  if (entry.sid) parts.push(`sid=${entry.sid}`);
  if (entry.ms !== undefined) parts.push(`${entry.ms}ms`);
  if (entry.data) {
    const compact = Object.entries(entry.data)
      .map(([k, v]) => `${k}=${typeof v === "string" ? v : JSON.stringify(v)}`)
      .join(" ");
    if (compact) parts.push(compact);
  }
  return parts.join(" ");
}

function emit(entry: LogEntry): void {
  const line = isDebugMode() ? formatJson(entry) : formatHuman(entry);
  process.stderr.write(`${line}\n`);
}

function makeLogFn(
  component: string,
  level: LogLevel,
  sessionId?: string,
): (op: string, msg: string, data?: Record<string, unknown>) => void {
  return (op, msg, data) => {
    if (!shouldLog(level)) return;
    const entry: LogEntry = {
      ts: new Date().toISOString(),
      level,
      component,
      op,
      msg,
    };
    const sid = shortSid(sessionId);
    if (sid) entry.sid = sid;
    if (data) {
      if (data.ms !== undefined) {
        entry.ms = data.ms as number;
        const { ms: _, ...rest } = data;
        if (Object.keys(rest).length > 0) entry.data = rest;
      } else {
        entry.data = data;
      }
    }
    emit(entry);
  };
}

/**
 * Create a component-scoped logger.
 *
 * @param component - short name identifying the source file (e.g. "main", "llm", "classifier")
 */
export function createLogger(component: string): Logger {
  return buildLogger(component, undefined);
}

function buildLogger(
  component: string,
  sessionId: string | undefined,
): Logger {
  return {
    debug: makeLogFn(component, "DEBUG", sessionId),
    info: makeLogFn(component, "INFO", sessionId),
    warn: makeLogFn(component, "WARN", sessionId),
    error: makeLogFn(component, "ERROR", sessionId),
    withSession(sid: string): Logger {
      return buildLogger(component, sid);
    },
  };
}
