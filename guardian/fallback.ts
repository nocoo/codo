import type { HookEvent, NotificationPayload } from "./types";
import { extractCommand } from "./types";
import { classifyBashEvent } from "./classifier";
import { createLogger } from "./logger";
import { basename } from "node:path";

const log = createLogger("fallback");

/** Extract project name from cwd. */
function projectName(event: HookEvent): string | undefined {
  const cwd = event.cwd as string | undefined;
  return cwd ? basename(cwd) : undefined;
}

/**
 * Generate a raw notification when Guardian is OFF or LLM fails.
 * Returns null to suppress the notification.
 */
export function fallbackNotification(
  event: HookEvent,
): NotificationPayload | null {
  const source = projectName(event);

  switch (event._hook) {
    case "notification":
      log.info("fallback", "generating notification", {
        title: (event.title as string) ?? "Codo",
      });
      return {
        title: (event.title as string) ?? "Codo",
        body: event.message as string | undefined,
        source,
      };

    case "stop": {
      const body = truncate(event.last_assistant_message, 100);
      log.info("fallback", "generating stop notification", {
        title: "Task Complete",
      });
      return {
        title: "Task Complete",
        body,
        source,
      };
    }

    case "post-tool-use": {
      const command = extractCommand(event);
      const tier = classifyBashEvent(command, "");
      if (tier !== "important") {
        log.debug("fallback", "post-tool-use skipped (not important)", {
          tier,
          cmd: command.slice(0, 60),
        });
        return null;
      }

      const toolName = (event.tool_name as string) ?? "Tool";
      log.info("fallback", "generating tool result notification", {
        title: `${toolName} result`,
      });
      return {
        title: `${toolName} result`,
        body: truncate(event.tool_response, 100),
        source,
      };
    }

    case "post-tool-use-failure": {
      const toolName = (event.tool_name as string) ?? "Tool";
      log.info("fallback", "generating failure notification", {
        title: `${toolName} failed`,
      });
      return {
        title: `${toolName} failed`,
        body: truncate(event.error, 100),
        source,
      };
    }

    case "session-start":
      log.info("fallback", "generating session-start notification");
      return {
        title: "Session Started",
        body: event.model as string | undefined,
        source,
      };

    case "session-end":
      log.debug("fallback", "session-end suppressed");
      return null;

    default:
      log.debug("fallback", "unhandled hook suppressed", {
        hook: event._hook,
      });
      return null;
  }
}

function truncate(
  s: unknown,
  max: number,
): string | undefined {
  if (typeof s !== "string") return undefined;
  return s.length <= max ? s : `${s.slice(0, max)}...`;
}
