import { describe, expect, test } from "bun:test";
import { classifyBashEvent, classifyEvent } from "./classifier";
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

describe("classifyBashEvent", () => {
  test("npm test → important", () => {
    expect(classifyBashEvent("npm test", "")).toBe("important");
  });

  test("swift build → important", () => {
    expect(classifyBashEvent("swift build", "")).toBe("important");
  });

  test("swift test → important", () => {
    expect(classifyBashEvent("swift test", "")).toBe("important");
  });

  test("git commit → important", () => {
    expect(classifyBashEvent('git commit -m "fix"', "")).toBe("important");
  });

  test("git push → important", () => {
    expect(classifyBashEvent("git push", "")).toBe("important");
  });

  test("bun test → important", () => {
    expect(classifyBashEvent("bun test", "")).toBe("important");
  });

  test("ls -la → contextual", () => {
    expect(classifyBashEvent("ls -la", "file1.ts")).toBe("contextual");
  });

  test("cat file.ts → contextual", () => {
    expect(classifyBashEvent("cat file.ts", "content")).toBe("contextual");
  });

  test("grep pattern → contextual", () => {
    expect(classifyBashEvent("grep pattern", "match")).toBe("contextual");
  });

  test("echo hello → noise", () => {
    expect(classifyBashEvent("echo hello", "hello")).toBe("noise");
  });

  test("pwd → noise", () => {
    expect(classifyBashEvent("pwd", "/tmp")).toBe("noise");
  });

  test("short output with no command → noise", () => {
    expect(classifyBashEvent("", "short")).toBe("noise");
  });
});

describe("classifyEvent", () => {
  test("Stop → important, trigger LLM", () => {
    const result = classifyEvent(
      makeEvent({ _hook: "stop", cwd: "/tmp" }),
    );
    expect(result.tier).toBe("important");
    expect(result.shouldTriggerLLM).toBe(true);
  });

  test("Notification → important, trigger LLM", () => {
    const result = classifyEvent(
      makeEvent({ _hook: "notification", cwd: "/tmp" }),
    );
    expect(result.tier).toBe("important");
    expect(result.shouldTriggerLLM).toBe(true);
  });

  test("PostToolUseFailure → important, trigger LLM", () => {
    const result = classifyEvent(
      makeEvent({ _hook: "post-tool-use-failure", cwd: "/tmp" }),
    );
    expect(result.tier).toBe("important");
    expect(result.shouldTriggerLLM).toBe(true);
  });

  test("SessionStart → contextual, no LLM", () => {
    const result = classifyEvent(
      makeEvent({ _hook: "session-start", cwd: "/tmp" }),
    );
    expect(result.tier).toBe("contextual");
    expect(result.shouldTriggerLLM).toBe(false);
  });

  test("SessionEnd → contextual, no LLM", () => {
    const result = classifyEvent(
      makeEvent({ _hook: "session-end", cwd: "/tmp" }),
    );
    expect(result.tier).toBe("contextual");
    expect(result.shouldTriggerLLM).toBe(false);
  });

  test("PostToolUse important (npm test) → important, trigger LLM", () => {
    const result = classifyEvent(
      makeEvent({
        _hook: "post-tool-use",
        cwd: "/tmp",
        command: "npm test",
        tool_response: "42 passed",
      }),
    );
    expect(result.tier).toBe("important");
    expect(result.shouldTriggerLLM).toBe(true);
  });

  test("PostToolUse contextual (ls) → contextual, no LLM", () => {
    const result = classifyEvent(
      makeEvent({
        _hook: "post-tool-use",
        cwd: "/tmp",
        command: "ls -la",
        tool_response: "file1.ts",
      }),
    );
    expect(result.tier).toBe("contextual");
    expect(result.shouldTriggerLLM).toBe(false);
  });

  test("PostToolUse with tool_input object → extracts command", () => {
    const result = classifyEvent(
      makeEvent({
        _hook: "post-tool-use",
        cwd: "/tmp",
        tool_name: "Bash",
        tool_input: { command: "npm test", timeout: 5000 },
        tool_response: "42 passed",
      }),
    );
    expect(result.tier).toBe("important");
    expect(result.shouldTriggerLLM).toBe(true);
  });

  test("PostToolUse with tool_input object noise → contextual", () => {
    const result = classifyEvent(
      makeEvent({
        _hook: "post-tool-use",
        cwd: "/tmp",
        tool_name: "Bash",
        tool_input: { command: "ls -la" },
        tool_response: "file1.ts",
      }),
    );
    expect(result.tier).toBe("contextual");
    expect(result.shouldTriggerLLM).toBe(false);
  });
});
