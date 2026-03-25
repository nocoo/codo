import { describe, expect, test } from "bun:test";
import { fallbackNotification } from "./fallback";
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

describe("fallbackNotification", () => {
  test("Notification with title and message", () => {
    const result = fallbackNotification(
      makeEvent({
        _hook: "notification",
        title: "T",
        message: "M",
      }),
    );
    expect(result).toEqual({ title: "T", body: "M" });
  });

  test("Notification no title → defaults to Codo", () => {
    const result = fallbackNotification(
      makeEvent({
        _hook: "notification",
        message: "M",
      }),
    );
    expect(result).toEqual({ title: "Codo", body: "M" });
  });

  test("Stop with last_assistant_message", () => {
    const result = fallbackNotification(
      makeEvent({
        _hook: "stop",
        last_assistant_message: "Did X",
      }),
    );
    expect(result?.title).toBe("Task Complete");
    expect(result?.body).toBe("Did X");
  });

  test("Stop long message truncated to 100 chars", () => {
    const longMsg = "a".repeat(150);
    const result = fallbackNotification(
      makeEvent({
        _hook: "stop",
        last_assistant_message: longMsg,
      }),
    );
    expect(result?.title).toBe("Task Complete");
    expect(result?.body?.length).toBe(103); // 100 + "..."
    expect(result?.body?.endsWith("...")).toBe(true);
  });

  test("PostToolUse test command → notification", () => {
    const result = fallbackNotification(
      makeEvent({
        _hook: "post-tool-use",
        tool_name: "Bash",
        command: "npm test",
        tool_response: "42 passed",
      }),
    );
    expect(result?.title).toBe("Bash result");
    expect(result?.body).toBe("42 passed");
  });

  test("PostToolUse noise command → suppressed", () => {
    const result = fallbackNotification(
      makeEvent({
        _hook: "post-tool-use",
        tool_name: "Bash",
        command: "ls",
      }),
    );
    expect(result).toBeNull();
  });

  test("PostToolUse with tool_input object → extracts command", () => {
    const result = fallbackNotification(
      makeEvent({
        _hook: "post-tool-use",
        tool_name: "Bash",
        tool_input: { command: "npm test", timeout: 5000 },
        tool_response: "42 passed",
      }),
    );
    expect(result?.title).toBe("Bash result");
    expect(result?.body).toBe("42 passed");
  });

  test("PostToolUse with tool_input object noise → suppressed", () => {
    const result = fallbackNotification(
      makeEvent({
        _hook: "post-tool-use",
        tool_name: "Bash",
        tool_input: { command: "ls -la" },
        tool_response: "file1.ts",
      }),
    );
    expect(result).toBeNull();
  });

  test("PostToolUseFailure", () => {
    const result = fallbackNotification(
      makeEvent({
        _hook: "post-tool-use-failure",
        tool_name: "Bash",
        error: "Command failed with exit code 1",
      }),
    );
    expect(result?.title).toBe("Bash failed");
    expect(result?.body).toBe("Command failed with exit code 1");
  });

  test("SessionStart with model", () => {
    const result = fallbackNotification(
      makeEvent({
        _hook: "session-start",
        model: "claude-sonnet-4-6",
      }),
    );
    expect(result?.title).toBe("Session Started");
    expect(result?.body).toBe("claude-sonnet-4-6");
  });

  test("SessionEnd → suppressed", () => {
    const result = fallbackNotification(
      makeEvent({ _hook: "session-end" }),
    );
    expect(result).toBeNull();
  });

  // ── truncate hardening: object-typed HookEvent fields ──

  test("Stop with object last_assistant_message → body undefined (not crash)", () => {
    const result = fallbackNotification(
      makeEvent({
        _hook: "stop",
        last_assistant_message: { text: "done", tokens: 42 },
      }),
    );
    expect(result?.title).toBe("Task Complete");
    expect(result?.body).toBeUndefined();
  });

  test("Stop with null last_assistant_message → body undefined", () => {
    const result = fallbackNotification(
      makeEvent({
        _hook: "stop",
        last_assistant_message: null,
      }),
    );
    expect(result?.title).toBe("Task Complete");
    expect(result?.body).toBeUndefined();
  });

  test("Stop with undefined last_assistant_message → body undefined", () => {
    const result = fallbackNotification(
      makeEvent({ _hook: "stop" }),
    );
    expect(result?.title).toBe("Task Complete");
    expect(result?.body).toBeUndefined();
  });

  test("Stop with numeric last_assistant_message → body undefined", () => {
    const result = fallbackNotification(
      makeEvent({
        _hook: "stop",
        last_assistant_message: 12345,
      }),
    );
    expect(result?.title).toBe("Task Complete");
    expect(result?.body).toBeUndefined();
  });

  test("PostToolUse with object tool_response → body undefined (not crash)", () => {
    const result = fallbackNotification(
      makeEvent({
        _hook: "post-tool-use",
        tool_name: "Bash",
        command: "npm test",
        tool_response: { stdout: "ok", exitCode: 0 },
      }),
    );
    expect(result?.title).toBe("Bash result");
    // truncate returns undefined for non-string input
    expect(result?.body).toBeUndefined();
  });

  test("PostToolUseFailure with object error → body undefined (not crash)", () => {
    const result = fallbackNotification(
      makeEvent({
        _hook: "post-tool-use-failure",
        tool_name: "Bash",
        error: { code: "ENOENT", message: "file not found" },
      }),
    );
    expect(result?.title).toBe("Bash failed");
    expect(result?.body).toBeUndefined();
  });

  test("PostToolUseFailure with array error → body undefined (not crash)", () => {
    const result = fallbackNotification(
      makeEvent({
        _hook: "post-tool-use-failure",
        tool_name: "Bash",
        error: ["error1", "error2"],
      }),
    );
    expect(result?.title).toBe("Bash failed");
    expect(result?.body).toBeUndefined();
  });

  test("source extracted from cwd basename", () => {
    const result = fallbackNotification(
      makeEvent({
        _hook: "notification",
        title: "T",
        cwd: "/Users/test/projects/my-app",
      }),
    );
    expect(result?.source).toBe("my-app");
  });
});
