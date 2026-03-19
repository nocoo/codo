import { describe, expect, test } from "bun:test";
import { extractCommand } from "./types";
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

describe("extractCommand", () => {
  test("top-level command string wins", () => {
    const event = makeEvent({
      _hook: "post-tool-use",
      command: "npm test",
      tool_input: { command: "bun test" },
    });
    expect(extractCommand(event)).toBe("npm test");
  });

  test("extracts command from tool_input object", () => {
    const event = makeEvent({
      _hook: "post-tool-use",
      tool_input: { command: "npm test", timeout: 5000 },
    });
    expect(extractCommand(event)).toBe("npm test");
  });

  test("tool_input as plain string", () => {
    const event = makeEvent({
      _hook: "post-tool-use",
      tool_input: "swift build",
    });
    expect(extractCommand(event)).toBe("swift build");
  });

  test("tool_input object without command key", () => {
    const event = makeEvent({
      _hook: "post-tool-use",
      tool_input: { content: "some data" },
    });
    expect(extractCommand(event)).toBe("");
  });

  test("no command and no tool_input", () => {
    const event = makeEvent({
      _hook: "post-tool-use",
      tool_name: "Bash",
    });
    expect(extractCommand(event)).toBe("");
  });

  test("tool_input is null", () => {
    const event = makeEvent({
      _hook: "post-tool-use",
      tool_input: null,
    });
    expect(extractCommand(event)).toBe("");
  });

  test("tool_input is array (edge case)", () => {
    const event = makeEvent({
      _hook: "post-tool-use",
      tool_input: ["npm", "test"],
    });
    expect(extractCommand(event)).toBe("");
  });
});
