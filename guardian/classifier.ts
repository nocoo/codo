import type { HookEvent } from "./types";
import { extractCommand } from "./types";
import { createLogger } from "./logger";

const log = createLogger("classifier");

export type EventTier = "important" | "contextual" | "noise";

export interface ClassifyResult {
  tier: EventTier;
  shouldTriggerLLM: boolean;
}

const IMPORTANT_PATTERNS = [
  /\btest\b/i,
  /\bbuild\b/i,
  /\bcompile\b/i,
  /\bdeploy\b/i,
  /\bgit\s+(commit|push|merge)\b/i,
  /\bnpm\s/i,
  /\bbun\s+test\b/i,
  /\bswift\s+(test|build)\b/i,
  /\bcargo\s+(test|build)\b/i,
  /\bmake\b/i,
];

const CONTEXTUAL_PATTERNS = [
  /\bls\b/,
  /\bcat\b/,
  /\bgrep\b/,
  /\bfind\b/,
  /\bhead\b/,
  /\btail\b/,
  /\bwc\b/,
  /\bfile\b/,
  /\bwhich\b/,
  /\brg\b/,
  /\bfd\b/,
  /\btree\b/,
  /\bgit\s+(status|log|diff|show|branch)\b/i,
];

/** Classify a PostToolUse event by command pattern. */
export function classifyBashEvent(command: string, output: string): EventTier {
  // Short output is noise
  if (output && output.length < 10 && !command) return "noise";

  if (!command) return "noise";

  // Check important patterns first
  for (const pattern of IMPORTANT_PATTERNS) {
    if (pattern.test(command)) {
      log.debug("classifyBash", "matched important", {
        cmd: command.slice(0, 80),
        tier: "important",
        pattern: pattern.source,
      });
      return "important";
    }
  }

  // Check contextual patterns
  for (const pattern of CONTEXTUAL_PATTERNS) {
    if (pattern.test(command)) {
      log.debug("classifyBash", "matched contextual", {
        cmd: command.slice(0, 80),
        tier: "contextual",
        pattern: pattern.source,
      });
      return "contextual";
    }
  }

  // Default: noise
  log.debug("classifyBash", "no pattern matched", {
    cmd: command.slice(0, 80),
    tier: "noise",
  });
  return "noise";
}

/** Classify any hook event for processing. */
export function classifyEvent(event: HookEvent): ClassifyResult {
  switch (event._hook) {
    case "stop":
    case "notification":
    case "post-tool-use-failure":
      return { tier: "important", shouldTriggerLLM: true };

    case "session-start":
    case "session-end":
      return { tier: "contextual", shouldTriggerLLM: false };

    case "post-tool-use": {
      const command = extractCommand(event);
      const output = (event.tool_response as string) ?? "";
      const tier = classifyBashEvent(command, output);
      log.debug("classifyEvent", "post-tool-use classified", {
        tool: (event.tool_name as string) ?? "unknown",
        cmd: command.slice(0, 80),
        tier,
        shouldTriggerLLM: tier === "important",
      });
      return {
        tier,
        shouldTriggerLLM: tier === "important",
      };
    }

    default:
      return { tier: "noise", shouldTriggerLLM: false };
  }
}
