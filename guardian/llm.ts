import OpenAI from "openai";
import Anthropic from "@anthropic-ai/sdk";
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

// ── Tool definitions (OpenAI format, also used as reference for Anthropic) ──

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

/** Anthropic tool format converted from OpenAI TOOLS. */
export const ANTHROPIC_TOOLS: Anthropic.Tool[] = TOOLS.map((t) => ({
  name: t.function.name,
  description: t.function.description ?? "",
  input_schema: t.function.parameters as Anthropic.Tool.InputSchema,
}));

export function buildSystemPrompt(state: StateStore): string {
  const parts: string[] = [
    "You are an AI notification assistant for a developer's coding session.",
    "Your role is to decide whether to send a macOS notification or suppress it.",
    "",
    "Guidelines:",
    "- ALWAYS write notification title and body in Chinese (简体中文)",
    "- Send notifications for important events: task completion, build/test results, errors, user action needed",
    "- Suppress noise: routine file operations, short commands, redundant status updates",
    "- Be concise: titles ≤ 20 chars, body ≤ 60 chars",
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

// ── OpenAI tool call parsing ──

function parseOpenAIToolCall(
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

// ── Anthropic tool call parsing ──

function parseAnthropicToolUse(
  block: Anthropic.ToolUseBlock,
): GuardianResult {
  const args = block.input as Record<string, unknown>;

  if (block.name === "send_notification") {
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

// ── Client creation ──

/**
 * Create an LLM client that dispatches to OpenAI or Anthropic SDK
 * based on config.sdkType.
 */
export function createLLMClient(
  config: GuardianConfig,
  openaiClient?: OpenAI,
  anthropicClient?: Anthropic,
): LLMClient {
  if (config.sdkType === "anthropic") {
    return createAnthropicLLMClient(config, anthropicClient);
  }
  return createOpenAILLMClient(config, openaiClient);
}

function createOpenAILLMClient(
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
          return parseOpenAIToolCall(toolCalls[0]);
        }

        const fb = fallbackNotification(event);
        return fb
          ? { action: "send", notification: fb }
          : { action: "suppress", reason: "no tool call from LLM" };
      } catch (error) {
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

function createAnthropicLLMClient(
  config: GuardianConfig,
  client?: Anthropic,
): LLMClient {
  const anthropic =
    client ??
    new Anthropic({
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

        const response = await anthropic.messages.create(
          {
            model: config.model,
            max_tokens: 1024,
            system: buildSystemPrompt(state),
            messages: [
              { role: "user", content: buildUserMessage(event) },
            ],
            tools: ANTHROPIC_TOOLS,
            tool_choice: { type: "any" },
          },
          { signal: controller.signal },
        );

        clearTimeout(timeout);

        const toolUse = response.content.find(
          (block): block is Anthropic.ToolUseBlock =>
            block.type === "tool_use",
        );

        if (toolUse) {
          return parseAnthropicToolUse(toolUse);
        }

        const fb = fallbackNotification(event);
        return fb
          ? { action: "send", notification: fb }
          : { action: "suppress", reason: "no tool use from LLM" };
      } catch (error) {
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
