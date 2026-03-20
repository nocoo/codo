#!/usr/bin/env bun

import { createInterface } from "node:readline";
import type { GuardianAction, GuardianConfig, HookEvent } from "./types";
import { extractCommand } from "./types";
import { createStateStore, updateState, evictStaleProjects } from "./state";
import type { StateStore } from "./state";
import { classifyEvent } from "./classifier";
import { createLLMClient, type LLMClient } from "./llm";
import { fallbackNotification } from "./fallback";
import {
  isValidProvider,
  resolveProviderConfig,
  type AiProvider,
  type SdkType,
} from "./providers";
import { createLogger } from "./logger";

const log = createLogger("main");

const EVICTION_INTERVAL_MS = 60 * 60 * 1000; // 1 hour
const EVICTION_MAX_AGE_MS = 24 * 60 * 60 * 1000; // 24 hours

function readConfig(): GuardianConfig {
  const providerRaw = process.env.CODO_PROVIDER ?? "custom";
  const provider: AiProvider = isValidProvider(providerRaw)
    ? providerRaw
    : "custom";
  const sdkTypeRaw = process.env.CODO_SDK_TYPE ?? "openai";
  const sdkType: SdkType =
    sdkTypeRaw === "anthropic" ? "anthropic" : "openai";

  const resolved = resolveProviderConfig({
    provider,
    apiKey: process.env.CODO_API_KEY ?? "",
    model: process.env.CODO_MODEL ?? "",
    baseURL: process.env.CODO_BASE_URL,
    sdkType,
  });

  return {
    ...resolved,
    contextLimit: Number.parseInt(
      process.env.CODO_CONTEXT_LIMIT ?? "160000",
      10,
    ),
  };
}

function emitAction(action: GuardianAction): void {
  const line = JSON.stringify(action);
  process.stdout.write(`${line}\n`);
}

export async function processLine(
  line: string,
  state: StateStore,
  llmClient: LLMClient,
): Promise<void> {
  log.debug("processLine", "recv", { bytes: line.length, preview: line.slice(0, 120) });

  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(line) as Record<string, unknown>;
  } catch {
    log.warn("processLine", "malformed JSON", { preview: line.slice(0, 100) });
    return;
  }

  // Determine if this is a hook event or a CodoMessage
  const hook = parsed._hook as string | undefined;

  if (hook) {
    // Hook event
    const event = parsed as unknown as HookEvent;
    const slog = event.session_id ? log.withSession(event.session_id) : log;
    slog.debug("processLine", "hook event parsed", { hook, cwd: event.cwd });
    await processHookEvent(event, state, llmClient);
  } else if (parsed.title) {
    // CodoMessage — forward directly as notification
    log.info("processLine", "direct CodoMessage", { title: parsed.title as string });
    emitAction({
      action: "send",
      notification: {
        title: parsed.title as string,
        body: parsed.body as string | undefined,
        subtitle: parsed.subtitle as string | undefined,
        sound: parsed.sound as string | undefined,
        threadId: parsed.threadId as string | undefined,
      },
    });
  } else {
    log.warn("processLine", "unrecognized message format");
  }
}

async function processHookEvent(
  event: HookEvent,
  state: StateStore,
  llmClient: LLMClient,
): Promise<void> {
  const slog = event.session_id ? log.withSession(event.session_id) : log;

  // Update state
  updateState(state, event);

  // Classify
  const { tier, shouldTriggerLLM } = classifyEvent(event);
  const cmd = extractCommand(event);

  slog.info("processHookEvent", "classified", {
    hook: event._hook,
    tier,
    shouldTriggerLLM,
    ...(cmd ? { cmd: cmd.slice(0, 80) } : {}),
  });

  if (shouldTriggerLLM) {
    // Send to LLM for intelligent processing
    const t0 = performance.now();
    const result = await llmClient.process(event, state);
    const elapsed = Math.round(performance.now() - t0);

    slog.info("processHookEvent", "llm result", {
      ms: elapsed,
      action: result.action,
      ...(result.notification ? { title: result.notification.title } : {}),
      ...(result.reason ? { reason: result.reason } : {}),
    });
    emitAction(result);
  } else {
    // Non-LLM events: use fallback or suppress
    const notification = fallbackNotification(event);
    if (notification) {
      slog.info("processHookEvent", "fallback notification", {
        title: notification.title,
      });
      emitAction({ action: "send", notification });
    } else {
      slog.debug("processHookEvent", "silent accumulation", {
        hook: event._hook,
        tier,
      });
    }
  }
}

// Only run main() when executed directly (not imported for testing)
if (import.meta.main) {
  const config = readConfig();
  log.info("startup", "config loaded", {
    provider: config.provider,
    model: config.model,
    sdkType: config.sdkType,
    baseURL: config.baseURL,
  });
  const state = createStateStore();
  const llmClient = createLLMClient(config);

  // Periodic stale project eviction
  setInterval(() => {
    evictStaleProjects(state, EVICTION_MAX_AGE_MS);
  }, EVICTION_INTERVAL_MS);

  // Read stdin line by line
  const rl = createInterface({
    input: process.stdin,
    terminal: false,
  });

  // Serial queue: each line must fully complete before the next starts.
  // readline `line` events fire without awaiting async handlers, so
  // concurrent processLine() calls would interleave state mutations.
  let queue: Promise<void> = Promise.resolve();

  rl.on("line", (line: string) => {
    if (!line.trim()) return;
    queue = queue.then(() => processLine(line, state, llmClient)).catch(
      (err) => {
        log.error("queue", "unhandled error", {
          error: err instanceof Error ? err.message : String(err),
          stack: err instanceof Error ? err.stack : undefined,
        });
      },
    );
  });

  // line handler is the only rl listener — close is handled after startup log

  log.info("startup", "guardian started");

  // Keep alive — never exit on stdin close, uncaught errors, or unhandled rejections
  rl.on("close", () => {
    log.warn("stdin", "stdin closed, waiting for reconnect");
    // Do NOT exit — the daemon may reopen a pipe or send SIGTERM to stop us
  });

  process.on("uncaughtException", (err) => {
    log.error("uncaught", "exception", {
      error: err.message,
      stack: err.stack,
    });
  });

  process.on("unhandledRejection", (reason) => {
    log.error("uncaught", "unhandled rejection", {
      error: reason instanceof Error ? reason.message : String(reason),
      stack: reason instanceof Error ? reason.stack : undefined,
    });
  });
}
