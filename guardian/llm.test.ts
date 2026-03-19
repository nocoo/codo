import { describe, expect, test } from "bun:test";
import type OpenAI from "openai";
import {
  TOOLS,
  buildSystemPrompt,
  buildUserMessage,
  createLLMClient,
} from "./llm";
import { createStateStore, updateState } from "./state";
import type { HookEvent } from "./types";

function makeEvent(
  overrides: Partial<HookEvent> & { _hook: HookEvent["_hook"] },
): HookEvent {
  return {
    session_id: "test-session",
    hook_event_name: overrides._hook,
    ...overrides,
  } as HookEvent;
}

function createMockOpenAI(
  response: Partial<OpenAI.Chat.Completions.ChatCompletion>,
): OpenAI {
  return {
    chat: {
      completions: {
        create: async () => response,
      },
    },
  } as unknown as OpenAI;
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
    expect(prompt).toContain("notification assistant");
    expect(prompt).toContain("send_notification");
    expect(prompt).toContain("suppress");
    expect(prompt).toContain("Active Projects");
    expect(prompt).toContain("Recent Events");
  });

  test("empty state has role and tools only", () => {
    const store = createStateStore();
    const prompt = buildSystemPrompt(store);
    expect(prompt).toContain("notification assistant");
    expect(prompt).toContain("send_notification");
    expect(prompt).not.toContain("Active Projects");
    expect(prompt).not.toContain("Recent Events");
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
});

describe("createLLMClient", () => {
  test("config sets base URL and model", () => {
    const config = {
      apiKey: "test-key",
      baseURL: "https://api.example.com/v1",
      model: "test-model",
      contextLimit: 100000,
    };

    // Just verify it doesn't throw
    const client = createLLMClient(config);
    expect(client).toBeDefined();
    expect(client.process).toBeFunction();
  });
});

describe("LLM process", () => {
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
    const client = createLLMClient(
      {
        apiKey: "test",
        baseURL: "http://localhost",
        model: "test",
        contextLimit: 100000,
      },
      mockOpenAI,
    );

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
    const client = createLLMClient(
      {
        apiKey: "test",
        baseURL: "http://localhost",
        model: "test",
        contextLimit: 100000,
      },
      mockOpenAI,
    );

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
    const client = createLLMClient(
      {
        apiKey: "test",
        baseURL: "http://localhost",
        model: "test",
        contextLimit: 100000,
      },
      mockOpenAI,
    );

    const state = createStateStore();
    const event = makeEvent({
      _hook: "stop",
      last_assistant_message: "Completed task",
    });

    const result = await client.process(event, state);
    // Should fall back to fallback notification
    expect(result.action).toBe("send");
    expect(result.notification?.title).toBe("Task Complete");
  });

  test("API error on suppressible event falls back correctly", async () => {
    const mockOpenAI = createErrorOpenAI(new Error("500 Internal Server Error"));
    const client = createLLMClient(
      {
        apiKey: "test",
        baseURL: "http://localhost",
        model: "test",
        contextLimit: 100000,
      },
      mockOpenAI,
    );

    const state = createStateStore();
    const event = makeEvent({
      _hook: "session-end",
    });

    const result = await client.process(event, state);
    // session-end fallback returns null → suppress
    expect(result.action).toBe("suppress");
    expect(result.reason).toContain("LLM error");
  });
});
