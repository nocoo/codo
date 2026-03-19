#!/usr/bin/env bun

import { createInterface } from "node:readline";
import type { GuardianAction, GuardianConfig, HookEvent } from "./types";
import { createStateStore, updateState, evictStaleProjects } from "./state";
import type { StateStore } from "./state";
import { classifyEvent } from "./classifier";
import { createLLMClient, type LLMClient } from "./llm";
import { fallbackNotification } from "./fallback";

const EVICTION_INTERVAL_MS = 60 * 60 * 1000; // 1 hour
const EVICTION_MAX_AGE_MS = 24 * 60 * 60 * 1000; // 24 hours

function readConfig(): GuardianConfig {
  return {
    apiKey: process.env.CODO_API_KEY ?? "",
    baseURL: process.env.CODO_BASE_URL ?? "https://api.openai.com/v1",
    model: process.env.CODO_MODEL ?? "gpt-4o-mini",
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
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(line) as Record<string, unknown>;
  } catch {
    // Malformed JSON — skip
    process.stderr.write(`guardian: malformed JSON: ${line.slice(0, 100)}\n`);
    return;
  }

  // Determine if this is a hook event or a CodoMessage
  const hook = parsed._hook as string | undefined;

  if (hook) {
    // Hook event
    const event = parsed as unknown as HookEvent;
    await processHookEvent(event, state, llmClient);
  } else if (parsed.title) {
    // CodoMessage — forward directly as notification
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
    process.stderr.write("guardian: unrecognized message format\n");
  }
}

async function processHookEvent(
  event: HookEvent,
  state: StateStore,
  llmClient: LLMClient,
): Promise<void> {
  // Update state
  updateState(state, event);

  // Classify
  const { shouldTriggerLLM } = classifyEvent(event);

  if (shouldTriggerLLM) {
    // Send to LLM for intelligent processing
    const result = await llmClient.process(event, state);
    emitAction(result);
  } else {
    // Non-LLM events: use fallback or suppress
    const notification = fallbackNotification(event);
    if (notification) {
      emitAction({ action: "send", notification });
    }
    // contextual/noise without notification → no output (silent accumulation)
  }
}

// Only run main() when executed directly (not imported for testing)
if (import.meta.main) {
  const config = readConfig();
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

  rl.on("line", async (line: string) => {
    if (!line.trim()) return;
    await processLine(line, state, llmClient);
  });

  rl.on("close", () => {
    process.exit(0);
  });

  process.stderr.write("guardian: started\n");
}
