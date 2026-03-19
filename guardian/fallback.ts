import type { HookEvent, NotificationPayload } from "./types";
import { extractCommand } from "./types";
import { classifyBashEvent } from "./classifier";

/**
 * Generate a raw notification when Guardian is OFF or LLM fails.
 * Returns null to suppress the notification.
 */
export function fallbackNotification(
  event: HookEvent,
): NotificationPayload | null {
  switch (event._hook) {
    case "notification":
      return {
        title: (event.title as string) ?? "Codo",
        body: event.message as string | undefined,
      };

    case "stop": {
      const body = truncate(event.last_assistant_message as string, 100);
      return {
        title: "Task Complete",
        body,
      };
    }

    case "post-tool-use": {
      const command = extractCommand(event);
      const tier = classifyBashEvent(command, "");
      if (tier !== "important") return null;

      const toolName = (event.tool_name as string) ?? "Tool";
      return {
        title: `${toolName} result`,
        body: truncate(event.tool_response as string, 100),
      };
    }

    case "post-tool-use-failure": {
      const toolName = (event.tool_name as string) ?? "Tool";
      return {
        title: `${toolName} failed`,
        body: truncate(event.error as string, 100),
      };
    }

    case "session-start":
      return {
        title: "Session Started",
        body: event.model as string | undefined,
      };

    case "session-end":
      return null;

    default:
      return null;
  }
}

function truncate(
  s: string | undefined | null,
  max: number,
): string | undefined {
  if (!s) return undefined;
  return s.length <= max ? s : `${s.slice(0, max)}...`;
}
