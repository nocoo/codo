import OpenAI from "openai";
import type {
  GuardianConfig,
  GuardianResult,
  HookEvent,
  NotificationPayload,
} from "./types";
import { extractCommand } from "./types";
import type { StateStore } from "./state";
import { serializeForPrompt } from "./state";
import { fallbackNotification } from "./fallback";

const LLM_TIMEOUT_MS = 10_000;

export interface LLMClient {
  process(event: HookEvent, state: StateStore): Promise<GuardianResult>;
}

export const TOOLS: OpenAI.Chat.Completions.ChatCompletionTool[] = [
  {
    type: "function",
    function: {
      name: "send_notification",
      description:
        "Send a macOS notification to the user. Use when the event is important enough to notify.",
      parameters: {
        type: "object",
        properties: {
          title: {
            type: "string",
            description: "Notification title (short, clear)",
          },
          body: {
            type: "string",
            description: "Notification body (1-2 sentences)",
          },
          subtitle: {
            type: "string",
            description: "Optional subtitle for context",
          },
          sound: {
            type: "string",
            enum: ["default", "none"],
            description: "Notification sound",
          },
          threadId: {
            type: "string",
            description: "Thread ID for grouping related notifications",
          },
        },
        required: ["title"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "suppress",
      description:
        "Suppress the notification. Use when the event is not important enough or is redundant.",
      parameters: {
        type: "object",
        properties: {
          reason: {
            type: "string",
            description: "Brief reason for suppression",
          },
        },
        required: ["reason"],
      },
    },
  },
];

export function buildSystemPrompt(state: StateStore): string {
  const parts: string[] = [
    "You are an AI notification assistant for a developer's coding session.",
    "Your role is to decide whether to send a macOS notification or suppress it.",
    "",
    "Guidelines:",
    "- Send notifications for important events: task completion, build/test results, errors, user action needed",
    "- Suppress noise: routine file operations, short commands, redundant status updates",
    "- Be concise: titles ≤ 50 chars, body ≤ 100 chars",
    "- Use context to avoid duplicate notifications",
    "- Group related notifications with threadId",
    "",
    "Available tools: send_notification, suppress",
  ];

  const stateStr = serializeForPrompt(state);
  if (stateStr) {
    parts.push("", "# Current State", "", stateStr);
  }

  return parts.join("\n");
}

export function buildUserMessage(event: HookEvent): string {
  const parts: string[] = [`Hook event: ${event._hook}`];

  switch (event._hook) {
    case "stop":
      if (event.last_assistant_message) {
        parts.push(
          `Last assistant message: ${event.last_assistant_message as string}`,
        );
      }
      break;

    case "notification":
      if (event.title) parts.push(`Title: ${event.title as string}`);
      if (event.message) parts.push(`Message: ${event.message as string}`);
      if (event.notification_type) {
        parts.push(`Type: ${event.notification_type as string}`);
      }
      break;

    case "post-tool-use":
      if (event.tool_name) {
        parts.push(`Tool: ${event.tool_name as string}`);
      }
      {
        const cmd = extractCommand(event);
        if (cmd) {
          parts.push(`Command: ${cmd}`);
        }
      }
      if (event.tool_response) {
        const response = event.tool_response as string;
        parts.push(
          `Output: ${response.length > 500 ? `${response.slice(0, 500)}...` : response}`,
        );
      }
      break;

    case "post-tool-use-failure":
      if (event.tool_name) {
        parts.push(`Tool: ${event.tool_name as string}`);
      }
      if (event.error) {
        parts.push(`Error: ${event.error as string}`);
      }
      break;

    case "session-start":
      if (event.model) parts.push(`Model: ${event.model as string}`);
      break;

    case "session-end":
      parts.push("Session ended");
      break;
  }

  return parts.join("\n");
}

function parseToolCall(
  toolCall: OpenAI.Chat.Completions.ChatCompletionMessageToolCall,
): GuardianResult {
  const args = JSON.parse(toolCall.function.arguments) as Record<
    string,
    unknown
  >;

  if (toolCall.function.name === "send_notification") {
    const notification: NotificationPayload = {
      title: args.title as string,
      body: args.body as string | undefined,
      subtitle: args.subtitle as string | undefined,
      sound: args.sound as string | undefined,
      threadId: args.threadId as string | undefined,
    };
    return { action: "send", notification };
  }

  return {
    action: "suppress",
    reason: (args.reason as string) ?? "suppressed by LLM",
  };
}

export function createLLMClient(
  config: GuardianConfig,
  client?: OpenAI,
): LLMClient {
  const openai =
    client ??
    new OpenAI({
      apiKey: config.apiKey,
      baseURL: config.baseURL,
    });

  return {
    async process(
      event: HookEvent,
      state: StateStore,
    ): Promise<GuardianResult> {
      try {
        const controller = new AbortController();
        const timeout = setTimeout(
          () => controller.abort(),
          LLM_TIMEOUT_MS,
        );

        const response = await openai.chat.completions.create(
          {
            model: config.model,
            messages: [
              { role: "system", content: buildSystemPrompt(state) },
              { role: "user", content: buildUserMessage(event) },
            ],
            tools: TOOLS,
            tool_choice: "required",
          },
          { signal: controller.signal },
        );

        clearTimeout(timeout);

        const toolCalls = response.choices[0]?.message?.tool_calls;
        if (toolCalls && toolCalls.length > 0) {
          return parseToolCall(toolCalls[0]);
        }

        // No tool call — fall back to raw notification
        const fb = fallbackNotification(event);
        return fb
          ? { action: "send", notification: fb }
          : { action: "suppress", reason: "no tool call from LLM" };
      } catch (error) {
        // Timeout or API error — fall back to raw notification
        const fb = fallbackNotification(event);
        return fb
          ? { action: "send", notification: fb }
          : {
              action: "suppress",
              reason: `LLM error: ${error instanceof Error ? error.message : "unknown"}`,
            };
      }
    },
  };
}
