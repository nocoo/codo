import { describe, expect, test } from "bun:test";
import type OpenAI from "openai";
import type Anthropic from "@anthropic-ai/sdk";
import {
  TOOLS,
  ANTHROPIC_TOOLS,
  COMPLETION_TOKEN_RESERVE,
  buildSystemPrompt,
  buildUserMessage,
  createLLMClient,
  stringify,
} from "./llm";
import { createStateStore, updateState } from "./state";
import type { GuardianConfig, HookEvent } from "./types";

function makeEvent(
  overrides: Partial<HookEvent> & { _hook: HookEvent["_hook"] },
): HookEvent {
  return {
    session_id: "test-session",
    hook_event_name: overrides._hook,
    ...overrides,
  } as HookEvent;
}

function openaiConfig(overrides?: Partial<GuardianConfig>): GuardianConfig {
  return {
    provider: "custom",
    apiKey: "test",
    baseURL: "http://localhost",
    model: "test",
    sdkType: "openai",
    contextLimit: 100000,
    ...overrides,
  };
}

function anthropicConfig(
  overrides?: Partial<GuardianConfig>,
): GuardianConfig {
  return {
    provider: "anthropic",
    apiKey: "test",
    baseURL: "http://localhost",
    model: "test",
    sdkType: "anthropic",
    contextLimit: 100000,
    ...overrides,
  };
}

function createMockOpenAI(
  response: Partial<OpenAI.Chat.Completions.ChatCompletion>,
) {
  let lastCreateArgs: Record<string, unknown> | undefined;
  const client = {
    chat: {
      completions: {
        create: async (args: Record<string, unknown>) => {
          lastCreateArgs = args;
          return response;
        },
      },
    },
  } as unknown as OpenAI;
  return { client, getLastArgs: () => lastCreateArgs };
}

function createErrorOpenAI(error: Error): OpenAI {
  return {
    chat: {
      completions: {
        create: async () => {
          throw error;
        },
      },
    },
  } as unknown as OpenAI;
}

function createMockAnthropic(
  response: Partial<Anthropic.Message>,
) {
  let lastCreateArgs: Record<string, unknown> | undefined;
  const client = {
    messages: {
      create: async (args: Record<string, unknown>) => {
        lastCreateArgs = args;
        return response;
      },
    },
  } as unknown as Anthropic;
  return { client, getLastArgs: () => lastCreateArgs };
}

function createErrorAnthropic(error: Error): Anthropic {
  return {
    messages: {
      create: async () => {
        throw error;
      },
    },
  } as unknown as Anthropic;
}

describe("buildSystemPrompt", () => {
  test("includes role and tools with state", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        cwd: "/tmp/proj-a",
        model: "claude-sonnet-4-6",
      }),
    );
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        cwd: "/tmp/proj-b",
        model: "gpt-4o",
      }),
    );

    for (let i = 0; i < 5; i++) {
      updateState(
        store,
        makeEvent({
          _hook: "post-tool-use",
          cwd: "/tmp/proj-a",
          tool_name: "Bash",
          command: `npm test run-${i}`,
          tool_response: `result-${i}`,
        }),
      );
    }

    const prompt = buildSystemPrompt(store);
    expect(prompt).toContain("通知助手");
    expect(prompt).toContain("send_notification");
    expect(prompt).toContain("suppress");
    expect(prompt).toContain("Active Projects");
    expect(prompt).toContain("Event History");
  });

  test("empty state has role and tools only, no project data", () => {
    const store = createStateStore();
    const prompt = buildSystemPrompt(store);
    expect(prompt).toContain("通知助手");
    expect(prompt).toContain("send_notification");
    // Empty state should not have Active Projects or event data sections
    expect(prompt).not.toContain("Active Projects");
    // "Event History" appears in context guidance rules (static),
    // but NOT as a "## Event History" data section
    expect(prompt).not.toContain("## Event History");
  });

  test("accepts contextLimit parameter and includes context guidance", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        cwd: "/tmp/proj",
        model: "test-model",
      }),
    );

    const prompt = buildSystemPrompt(store, 8000);
    expect(prompt).toContain("上下文利用");
    expect(prompt).toContain("Event History");
    expect(prompt).toContain("Sent Notifications");
  });

  test("contextLimit defaults to 160k when not provided", () => {
    const store = createStateStore();
    // Should not throw and should produce a valid prompt
    const prompt = buildSystemPrompt(store);
    expect(prompt).toContain("通知助手");
    expect(prompt).toContain("上下文利用");
  });
});

describe("buildUserMessage", () => {
  test("Stop event includes last_assistant_message", () => {
    const msg = buildUserMessage(
      makeEvent({
        _hook: "stop",
        last_assistant_message: "Refactored auth module",
      }),
    );
    expect(msg).toContain("stop");
    expect(msg).toContain("Refactored auth module");
  });

  test("Notification event includes title and message", () => {
    const msg = buildUserMessage(
      makeEvent({
        _hook: "notification",
        title: "Permission needed",
        message: "Approve Bash?",
        notification_type: "permission_prompt",
      }),
    );
    expect(msg).toContain("notification");
    expect(msg).toContain("Permission needed");
    expect(msg).toContain("Approve Bash?");
    expect(msg).toContain("permission_prompt");
  });

  test("PostToolUse event includes tool details", () => {
    const msg = buildUserMessage(
      makeEvent({
        _hook: "post-tool-use",
        tool_name: "Bash",
        command: "npm test",
        tool_response: "42 tests passed",
      }),
    );
    expect(msg).toContain("Bash");
    expect(msg).toContain("npm test");
    expect(msg).toContain("42 tests passed");
  });
});

describe("TOOLS", () => {
  test("contains send_notification and suppress", () => {
    const names = TOOLS.map((t) => t.function.name);
    expect(names).toContain("send_notification");
    expect(names).toContain("suppress");
  });

  test("ANTHROPIC_TOOLS mirrors OpenAI TOOLS", () => {
    const names = ANTHROPIC_TOOLS.map((t) => t.name);
    expect(names).toContain("send_notification");
    expect(names).toContain("suppress");
    expect(ANTHROPIC_TOOLS.length).toBe(TOOLS.length);
  });

  test("COMPLETION_TOKEN_RESERVE is 1024", () => {
    expect(COMPLETION_TOKEN_RESERVE).toBe(1024);
  });
});

describe("createLLMClient", () => {
  test("OpenAI config creates client", () => {
    const client = createLLMClient(openaiConfig());
    expect(client).toBeDefined();
    expect(client.process).toBeFunction();
  });

  test("Anthropic config creates client", () => {
    const client = createLLMClient(anthropicConfig());
    expect(client).toBeDefined();
    expect(client.process).toBeFunction();
  });
});

describe("OpenAI LLM process", () => {
  test("mock returns send action", async () => {
    const mockResponse: Partial<OpenAI.Chat.Completions.ChatCompletion> = {
      choices: [
        {
          index: 0,
          finish_reason: "stop",
          logprobs: null,
          message: {
            role: "assistant",
            content: null,
            refusal: null,
            tool_calls: [
              {
                id: "call_1",
                type: "function",
                function: {
                  name: "send_notification",
                  arguments: JSON.stringify({
                    title: "Build Complete",
                    body: "All 42 tests passed",
                    sound: "default",
                  }),
                },
              },
            ],
          },
        },
      ],
    };

    const mockOpenAI = createMockOpenAI(mockResponse);
    const client = createLLMClient(openaiConfig(), mockOpenAI.client);

    const state = createStateStore();
    const event = makeEvent({
      _hook: "stop",
      last_assistant_message: "Built and tested",
    });

    const result = await client.process(event, state);
    expect(result.action).toBe("send");
    expect(result.notification?.title).toBe("Build Complete");
    expect(result.notification?.body).toBe("All 42 tests passed");
  });

  test("mock returns suppress action", async () => {
    const mockResponse: Partial<OpenAI.Chat.Completions.ChatCompletion> = {
      choices: [
        {
          index: 0,
          finish_reason: "stop",
          logprobs: null,
          message: {
            role: "assistant",
            content: null,
            refusal: null,
            tool_calls: [
              {
                id: "call_2",
                type: "function",
                function: {
                  name: "suppress",
                  arguments: JSON.stringify({
                    reason: "routine operation",
                  }),
                },
              },
            ],
          },
        },
      ],
    };

    const mockOpenAI = createMockOpenAI(mockResponse);
    const client = createLLMClient(openaiConfig(), mockOpenAI.client);

    const state = createStateStore();
    const event = makeEvent({
      _hook: "post-tool-use",
      command: "ls -la",
    });

    const result = await client.process(event, state);
    expect(result.action).toBe("suppress");
    expect(result.reason).toBe("routine operation");
  });

  test("API error falls back to raw notification", async () => {
    const mockOpenAI = createErrorOpenAI(new Error("API rate limited"));
    const client = createLLMClient(openaiConfig(), mockOpenAI);

    const state = createStateStore();
    const event = makeEvent({
      _hook: "stop",
      last_assistant_message: "Completed task",
    });

    const result = await client.process(event, state);
    expect(result.action).toBe("send");
    expect(result.notification?.title).toBe("Task Complete");
  });

  test("API error on suppressible event falls back correctly", async () => {
    const mockOpenAI = createErrorOpenAI(
      new Error("500 Internal Server Error"),
    );
    const client = createLLMClient(openaiConfig(), mockOpenAI);

    const state = createStateStore();
    const event = makeEvent({ _hook: "session-end" });

    const result = await client.process(event, state);
    expect(result.action).toBe("suppress");
    expect(result.reason).toContain("LLM error");
  });

  test("request includes max_tokens: COMPLETION_TOKEN_RESERVE", async () => {
    const mockResponse: Partial<OpenAI.Chat.Completions.ChatCompletion> = {
      choices: [
        {
          index: 0,
          finish_reason: "stop",
          logprobs: null,
          message: {
            role: "assistant",
            content: null,
            refusal: null,
            tool_calls: [
              {
                id: "call_mt",
                type: "function",
                function: {
                  name: "suppress",
                  arguments: JSON.stringify({ reason: "test" }),
                },
              },
            ],
          },
        },
      ],
    };

    const mock = createMockOpenAI(mockResponse);
    const client = createLLMClient(openaiConfig(), mock.client);
    const state = createStateStore();
    const event = makeEvent({ _hook: "stop", last_assistant_message: "done" });

    await client.process(event, state);
    expect(mock.getLastArgs()?.max_tokens).toBe(COMPLETION_TOKEN_RESERVE);
  });
});

describe("Anthropic LLM process", () => {
  test("mock returns send action via tool_use", async () => {
    const mockResponse: Partial<Anthropic.Message> = {
      content: [
        {
          type: "tool_use",
          id: "toolu_1",
          name: "send_notification",
          input: {
            title: "Build Done",
            body: "All tests passed",
            sound: "default",
          },
        },
      ],
    };

    const mockAnthropic = createMockAnthropic(mockResponse);
    const client = createLLMClient(
      anthropicConfig(),
      undefined,
      mockAnthropic.client,
    );

    const state = createStateStore();
    const event = makeEvent({
      _hook: "stop",
      last_assistant_message: "Built and tested",
    });

    const result = await client.process(event, state);
    expect(result.action).toBe("send");
    expect(result.notification?.title).toBe("Build Done");
    expect(result.notification?.body).toBe("All tests passed");
  });

  test("mock returns suppress action via tool_use", async () => {
    const mockResponse: Partial<Anthropic.Message> = {
      content: [
        {
          type: "tool_use",
          id: "toolu_2",
          name: "suppress",
          input: { reason: "routine file read" },
        },
      ],
    };

    const mockAnthropic = createMockAnthropic(mockResponse);
    const client = createLLMClient(
      anthropicConfig(),
      undefined,
      mockAnthropic.client,
    );

    const state = createStateStore();
    const event = makeEvent({
      _hook: "post-tool-use",
      command: "cat file.txt",
    });

    const result = await client.process(event, state);
    expect(result.action).toBe("suppress");
    expect(result.reason).toBe("routine file read");
  });

  test("API error falls back to raw notification", async () => {
    const mockAnthropic = createErrorAnthropic(
      new Error("overloaded_error"),
    );
    const client = createLLMClient(
      anthropicConfig(),
      undefined,
      mockAnthropic,
    );

    const state = createStateStore();
    const event = makeEvent({
      _hook: "stop",
      last_assistant_message: "Completed refactoring",
    });

    const result = await client.process(event, state);
    expect(result.action).toBe("send");
    expect(result.notification?.title).toBe("Task Complete");
  });

  test("no tool_use block falls back", async () => {
    const mockResponse: Partial<Anthropic.Message> = {
      content: [{ type: "text", text: "I should send a notification" }],
    };

    const mockAnthropic = createMockAnthropic(mockResponse);
    const client = createLLMClient(
      anthropicConfig(),
      undefined,
      mockAnthropic.client,
    );

    const state = createStateStore();
    const event = makeEvent({
      _hook: "stop",
      last_assistant_message: "Done",
    });

    const result = await client.process(event, state);
    expect(result.action).toBe("send");
    expect(result.notification?.title).toBe("Task Complete");
  });

  test("request includes max_tokens: COMPLETION_TOKEN_RESERVE", async () => {
    const mockResponse: Partial<Anthropic.Message> = {
      content: [
        {
          type: "tool_use",
          id: "toolu_mt",
          name: "suppress",
          input: { reason: "test" },
        },
      ],
    };

    const mock = createMockAnthropic(mockResponse);
    const client = createLLMClient(
      anthropicConfig(),
      undefined,
      mock.client,
    );
    const state = createStateStore();
    const event = makeEvent({ _hook: "stop", last_assistant_message: "done" });

    await client.process(event, state);
    expect(mock.getLastArgs()?.max_tokens).toBe(COMPLETION_TOKEN_RESERVE);
  });
});

// ── stringify() edge cases ──

describe("stringify", () => {
  test("string within limit returned as-is", () => {
    expect(stringify("hello", 10)).toBe("hello");
  });

  test("string exceeding limit is truncated with ellipsis", () => {
    expect(stringify("abcdefghij", 5)).toBe("abcde...");
  });

  test("null returns empty string", () => {
    expect(stringify(null, 100)).toBe("");
  });

  test("undefined returns empty string", () => {
    expect(stringify(undefined, 100)).toBe("");
  });

  test("number is JSON.stringified", () => {
    expect(stringify(42, 100)).toBe("42");
  });

  test("object is JSON.stringified", () => {
    const result = stringify({ key: "value" }, 100);
    expect(result).toBe('{"key":"value"}');
  });

  test("object exceeding limit is truncated", () => {
    const result = stringify({ key: "value" }, 5);
    expect(result).toBe('{"key...');
    expect(result.length).toBe(8); // 5 + "..."
  });

  test("array is JSON.stringified", () => {
    const result = stringify(["a", "b"], 100);
    expect(result).toBe('["a","b"]');
  });

  test("boolean is JSON.stringified", () => {
    expect(stringify(true, 100)).toBe("true");
  });

  test("circular reference falls back to String()", () => {
    const obj: Record<string, unknown> = {};
    obj.self = obj;
    const result = stringify(obj, 100);
    expect(result).toBe("[object Object]");
  });
});

// ── buildUserMessage with object-typed HookEvent fields ──

describe("buildUserMessage object payloads", () => {
  test("stop with object last_assistant_message → JSON stringified", () => {
    const msg = buildUserMessage(
      makeEvent({
        _hook: "stop",
        last_assistant_message: { text: "done", tokens: 42 },
      }),
    );
    expect(msg).toContain("stop");
    expect(msg).toContain('"text"');
    expect(msg).toContain('"done"');
    // Should NOT contain [object Object]
    expect(msg).not.toContain("[object Object]");
  });

  test("stop with null last_assistant_message → no crash", () => {
    const msg = buildUserMessage(
      makeEvent({
        _hook: "stop",
        last_assistant_message: null,
      }),
    );
    expect(msg).toContain("stop");
  });

  test("post-tool-use with object tool_response → JSON stringified", () => {
    const msg = buildUserMessage(
      makeEvent({
        _hook: "post-tool-use",
        tool_name: "Bash",
        command: "npm test",
        tool_response: { stdout: "42 passed", exitCode: 0 },
      }),
    );
    expect(msg).toContain("Bash");
    expect(msg).toContain("npm test");
    expect(msg).toContain('"stdout"');
    expect(msg).toContain("42 passed");
    expect(msg).not.toContain("[object Object]");
  });

  test("post-tool-use with array tool_response → JSON stringified", () => {
    const msg = buildUserMessage(
      makeEvent({
        _hook: "post-tool-use",
        tool_name: "Bash",
        command: "npm test",
        tool_response: ["line1", "line2"],
      }),
    );
    expect(msg).toContain("line1");
    expect(msg).toContain("line2");
  });

  test("post-tool-use-failure with object error → JSON stringified", () => {
    const msg = buildUserMessage(
      makeEvent({
        _hook: "post-tool-use-failure",
        tool_name: "Bash",
        error: { code: "ENOENT", message: "not found" },
      }),
    );
    expect(msg).toContain("Bash");
    expect(msg).toContain("ENOENT");
    expect(msg).toContain("not found");
    expect(msg).not.toContain("[object Object]");
  });

  test("post-tool-use with long object tool_response → truncated", () => {
    const bigObj = { data: "x".repeat(2100) };
    const msg = buildUserMessage(
      makeEvent({
        _hook: "post-tool-use",
        tool_name: "Bash",
        command: "npm test",
        tool_response: bigObj,
      }),
    );
    expect(msg).toContain("...");
    // The stringify limit is 2000, so output should be bounded
    const outputLine = msg.split("\n").find((l) => l.startsWith("Output:"));
    expect(outputLine).toBeDefined();
    // 2000 chars + "..." + "Output: " prefix
    expect(outputLine!.length).toBeLessThan(2020);
  });

  test("post-tool-use with tool_input object extracts command", () => {
    const msg = buildUserMessage(
      makeEvent({
        _hook: "post-tool-use",
        tool_name: "Bash",
        tool_input: { command: "npm test", timeout: 5000 },
        tool_response: "42 passed",
      }),
    );
    expect(msg).toContain("npm test");
    expect(msg).toContain("42 passed");
  });

  test("notification with all fields", () => {
    const msg = buildUserMessage(
      makeEvent({
        _hook: "notification",
        title: "Permission",
        message: "Allow access?",
        notification_type: "permission_prompt",
      }),
    );
    expect(msg).toContain("Permission");
    expect(msg).toContain("Allow access?");
    expect(msg).toContain("permission_prompt");
  });

  test("session-start with model", () => {
    const msg = buildUserMessage(
      makeEvent({
        _hook: "session-start",
        model: "claude-sonnet-4-6",
      }),
    );
    expect(msg).toContain("session-start");
    expect(msg).toContain("claude-sonnet-4-6");
  });

  test("session-end", () => {
    const msg = buildUserMessage(makeEvent({ _hook: "session-end" }));
    expect(msg).toContain("session-end");
    expect(msg).toContain("Session ended");
  });
});
