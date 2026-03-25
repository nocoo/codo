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
import { createLogger } from "./logger";

const log = createLogger("llm");

const LLM_TIMEOUT_MS = 30_000;

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
        "发送macOS通知给用户。title和body必须使用简体中文，必须是你自己撰写的摘要，禁止复制原文。",
      parameters: {
        type: "object",
        properties: {
          title: {
            type: "string",
            description: "通知标题，简体中文，不超过15个汉字",
          },
          body: {
            type: "string",
            description: "通知正文，简体中文摘要，2-5句概括要点，必须用自己的话总结，禁止复制原始输出",
          },
          subtitle: {
            type: "string",
            description: "可选副标题，简体中文",
          },
          source: {
            type: "string",
            description: "项目名称（cwd的basename），英文",
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

export function buildSystemPrompt(
  state: StateStore,
  contextLimit: number = 160_000,
): string {
  // ~3 chars/token rough estimate; used as soft upper limit only.
  // Clamp to [2_000, 600_000] — floor prevents negative/tiny budgets on
  // ultra-small context models, ceiling prevents wasteful over-allocation.
  const rawBudget = (contextLimit - 2024) * 3;
  const charBudget = Math.min(Math.max(rawBudget, 2_000), 600_000);

  const parts: string[] = [
    "你是一个开发者编码会话的AI通知助手。",
    "你的职责是判断是否发送macOS通知，并撰写简洁的中文摘要。",
    "",
    "## 强制规则",
    "- 所有通知的 title 和 body 必须使用简体中文，禁止使用英文",
    "- title 不超过15个汉字",
    "- body 用2-5句简体中文概括要点，不需要凑数，信息量不大时1-2句即可",
    "- body 必须是你自己撰写的摘要，禁止复制粘贴原文",
    "- body 必须是你自己的总结，绝对禁止直接复制粘贴原始输出内容",
    "- 即使原文是 Markdown / 代码 / 日志，也必须用自然语言概括其含义",
    "- 如果原始信息是英文，翻译并概括为中文",
    "",
    "## 通知策略",
    "- 发送通知：任务完成、构建/测试结果、错误、需要用户操作",
    "- 抑制噪声：日常文件操作、短命令、重复状态更新",
    "- 用 threadId 分组相关通知，避免重复",
    "",
    "## 上下文利用",
    "- Event History 包含该项目的近期事件流，利用它理解任务进展",
    "- Sent Notifications 列出之前已发送的通知，避免发送相似内容",
    '- 如果某个任务经历了多次失败后成功，在通知中体现这个过程（如"经过多轮调试，XXX终于通过"）',
    "- 如果当前事件是一系列操作的最终结果，总结整个过程而非仅描述最后一步",
    "",
    "可用工具：send_notification, suppress",
  ];

  const stateStr = serializeForPrompt(state, charBudget);
  if (stateStr) {
    parts.push("", "# Current State", "", stateStr);
  }

  return parts.join("\n");
}

/**
 * Safely coerce an unknown HookEvent field to a bounded string.
 * - string → truncate to max
 * - null/undefined → ""
 * - object/array → JSON.stringify, then truncate
 */
export function stringify(v: unknown, max: number): string {
  if (typeof v === "string")
    return v.length <= max ? v : `${v.slice(0, max)}...`;
  if (v == null) return "";
  try {
    const s = JSON.stringify(v);
    return s.length <= max ? s : `${s.slice(0, max)}...`;
  } catch {
    return String(v).slice(0, max);
  }
}

export function buildUserMessage(event: HookEvent): string {
  const parts: string[] = [`Hook event: ${event._hook}`];

  switch (event._hook) {
    case "stop":
      if (event.last_assistant_message) {
        parts.push(
          `Last assistant message: ${stringify(event.last_assistant_message, 2000)}`,
        );
      }
      break;

    case "notification":
      if (event.title) parts.push(`Title: ${String(event.title)}`);
      if (event.message) parts.push(`Message: ${String(event.message)}`);
      if (event.notification_type) {
        parts.push(`Type: ${String(event.notification_type)}`);
      }
      break;

    case "post-tool-use":
      if (event.tool_name) {
        parts.push(`Tool: ${String(event.tool_name)}`);
      }
      {
        const cmd = extractCommand(event);
        if (cmd) {
          parts.push(`Command: ${cmd}`);
        }
      }
      if (event.tool_response) {
        parts.push(
          `Output: ${stringify(event.tool_response, 2000)}`,
        );
      }
      break;

    case "post-tool-use-failure":
      if (event.tool_name) {
        parts.push(`Tool: ${String(event.tool_name)}`);
      }
      if (event.error) {
        parts.push(`Error: ${stringify(event.error, 2000)}`);
      }
      break;

    case "session-start":
      if (event.model) parts.push(`Model: ${String(event.model)}`);
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
      source: args.source as string | undefined,
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
      source: args.source as string | undefined,
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
        const systemPrompt = buildSystemPrompt(state, config.contextLimit);
        const userMessage = buildUserMessage(event);

        log.debug("openai.req", "sending request", {
          model: config.model,
          hook: event._hook,
          systemPrompt_chars: String(systemPrompt.length),
          userMessage_chars: String(userMessage.length),
          estimated_tokens: String(
            Math.round((systemPrompt.length + userMessage.length) / 3),
          ),
        });

        const controller = new AbortController();
        const timeout = setTimeout(
          () => controller.abort(),
          LLM_TIMEOUT_MS,
        );
        const t0 = performance.now();

        const response = await openai.chat.completions.create(
          {
            model: config.model,
            messages: [
              { role: "system", content: systemPrompt },
              { role: "user", content: userMessage },
            ],
            tools: TOOLS,
            tool_choice: "required",
          },
          { signal: controller.signal },
        );

        clearTimeout(timeout);
        const elapsed = Math.round(performance.now() - t0);

        const choice = response.choices[0];
        const toolCalls = choice?.message?.tool_calls;
        log.info("openai.res", "response received", {
          ms: elapsed,
          finish_reason: choice?.finish_reason ?? "unknown",
          tool_calls: toolCalls?.length ?? 0,
          usage_prompt: response.usage?.prompt_tokens,
          usage_completion: response.usage?.completion_tokens,
        });

        if (toolCalls && toolCalls.length > 0) {
          const tc = toolCalls[0];
          log.debug("openai.tool", "tool call parsed", {
            name: tc.function.name,
            args: tc.function.arguments.slice(0, 200),
          });
          return parseOpenAIToolCall(tc);
        }

        log.warn("openai.notool", "no tool call in response", {
          finish_reason: choice?.finish_reason ?? "unknown",
        });
        const fb = fallbackNotification(event);
        return fb
          ? { action: "send", notification: fb }
          : { action: "suppress", reason: "no tool call from LLM" };
      } catch (error) {
        log.error("openai.catch", "request failed", {
          error: error instanceof Error ? error.name : "unknown",
          message: error instanceof Error ? error.message : String(error),
        });
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
        const systemPrompt = buildSystemPrompt(state, config.contextLimit);
        const userMessage = buildUserMessage(event);

        log.debug("anthropic.req", "sending request", {
          model: config.model,
          hook: event._hook,
          systemPrompt_chars: String(systemPrompt.length),
          userMessage_chars: String(userMessage.length),
          estimated_tokens: String(
            Math.round((systemPrompt.length + userMessage.length) / 3),
          ),
        });

        const controller = new AbortController();
        const timeout = setTimeout(
          () => controller.abort(),
          LLM_TIMEOUT_MS,
        );
        const t0 = performance.now();

        const response = await anthropic.messages.create(
          {
            model: config.model,
            max_tokens: 1024,
            system: systemPrompt,
            messages: [
              { role: "user", content: userMessage },
            ],
            tools: ANTHROPIC_TOOLS,
            tool_choice: { type: "any" },
          },
          { signal: controller.signal },
        );

        clearTimeout(timeout);
        const elapsed = Math.round(performance.now() - t0);

        log.info("anthropic.res", "response received", {
          ms: elapsed,
          stop_reason: response.stop_reason,
          content_types: response.content.map((b) => b.type).join(","),
          usage_input: response.usage?.input_tokens,
          usage_output: response.usage?.output_tokens,
        });

        const toolUse = response.content.find(
          (block): block is Anthropic.ToolUseBlock =>
            block.type === "tool_use",
        );

        if (toolUse) {
          log.debug("anthropic.tool", "tool use parsed", {
            name: toolUse.name,
            args: JSON.stringify(toolUse.input).slice(0, 200),
          });
          return parseAnthropicToolUse(toolUse);
        }

        log.warn("anthropic.notool", "no tool_use block found, falling back", {
          stop_reason: response.stop_reason,
        });
        const fb = fallbackNotification(event);
        return fb
          ? { action: "send", notification: fb }
          : { action: "suppress", reason: "no tool use from LLM" };
      } catch (error) {
        log.error("anthropic.catch", "request failed", {
          error: error instanceof Error ? error.name : "unknown",
          message: error instanceof Error ? error.message : String(error),
        });
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
