import { describe, expect, test } from "bun:test";
import {
  canonicalizePath,
  createStateStore,
  evictStaleProjects,
  getProject,
  serializeForPrompt,
  updateState,
} from "./state";
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

describe("canonicalizePath", () => {
  test("resolves existing path", () => {
    const result = canonicalizePath("/tmp");
    expect(result).toContain("tmp");
  });

  test("returns input for non-existent path", () => {
    const result = canonicalizePath("/nonexistent/path/abc123");
    expect(result).toBe("/nonexistent/path/abc123");
  });
});

describe("getProject", () => {
  test("returns undefined for unknown cwd", () => {
    const store = createStateStore();
    expect(getProject(store, "/unknown")).toBeUndefined();
  });
});

describe("updateState", () => {
  test("SessionStart creates project", () => {
    const store = createStateStore();
    const event = makeEvent({
      _hook: "session-start",
      cwd: "/tmp/proj",
      model: "claude-sonnet-4-6",
    });
    updateState(store, event);

    const project = getProject(store, "/tmp/proj");
    expect(project).toBeDefined();
    expect(project?.sessionId).toBe("test-session");
    expect(project?.model).toBe("claude-sonnet-4-6");
    expect(project?.sessionActive).toBe(true);
  });

  test("PostToolUse important updates lastStatus", () => {
    const store = createStateStore();
    // First create the project
    updateState(
      store,
      makeEvent({ _hook: "session-start", cwd: "/tmp/proj" }),
    );

    updateState(
      store,
      makeEvent({
        _hook: "post-tool-use",
        cwd: "/tmp/proj",
        tool_name: "Bash",
        command: "npm test",
        tool_response: "42 tests passed",
      }),
    );

    const project = getProject(store, "/tmp/proj");
    expect(project?.lastStatus).toBe("42 tests passed");
    expect(store.events.length).toBeGreaterThan(0);
  });

  test("PostToolUse contextual adds event but no lastStatus", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({ _hook: "session-start", cwd: "/tmp/proj" }),
    );

    const eventsBefore = store.events.length;
    updateState(
      store,
      makeEvent({
        _hook: "post-tool-use",
        cwd: "/tmp/proj",
        tool_name: "Bash",
        command: "ls -la",
        tool_response: "file1.ts file2.ts",
      }),
    );

    const project = getProject(store, "/tmp/proj");
    expect(project?.lastStatus).toBeNull();
    expect(store.events.length).toBeGreaterThan(eventsBefore);
  });

  test("PostToolUse noise has no state change", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({ _hook: "session-start", cwd: "/tmp/proj" }),
    );

    const eventsBefore = store.events.length;
    updateState(
      store,
      makeEvent({
        _hook: "post-tool-use",
        cwd: "/tmp/proj",
        tool_name: "Bash",
        command: "echo hello",
        tool_response: "hello",
      }),
    );

    expect(store.events.length).toBe(eventsBefore); // no event added
  });

  test("Stop updates task", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({ _hook: "session-start", cwd: "/tmp/proj" }),
    );

    updateState(
      store,
      makeEvent({
        _hook: "stop",
        cwd: "/tmp/proj",
        last_assistant_message: "Refactored auth module, all tests pass",
      }),
    );

    const project = getProject(store, "/tmp/proj");
    expect(project?.task).toBe("Refactored auth module, all tests pass");
  });

  test("Stop generic does NOT overwrite specific task", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({ _hook: "session-start", cwd: "/tmp/proj" }),
    );

    // Set a specific task first
    updateState(
      store,
      makeEvent({
        _hook: "stop",
        cwd: "/tmp/proj",
        last_assistant_message: "Implemented OAuth2 login flow",
      }),
    );

    // Generic "done" should not overwrite
    updateState(
      store,
      makeEvent({
        _hook: "stop",
        cwd: "/tmp/proj",
        last_assistant_message: "done",
      }),
    );

    const project = getProject(store, "/tmp/proj");
    expect(project?.task).toBe("Implemented OAuth2 login flow");
  });

  test("Notification recorded in recentNotifications", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({ _hook: "session-start", cwd: "/tmp/proj" }),
    );

    updateState(
      store,
      makeEvent({
        _hook: "notification",
        cwd: "/tmp/proj",
        title: "Permission needed",
        message: "Approve Bash?",
      }),
    );

    const project = getProject(store, "/tmp/proj");
    expect(project?.recentNotifications.length).toBe(1);
    expect(project?.recentNotifications[0].title).toBe("Permission needed");
  });

  test("SessionEnd sets sessionActive false", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({ _hook: "session-start", cwd: "/tmp/proj" }),
    );

    updateState(
      store,
      makeEvent({
        _hook: "session-end",
        cwd: "/tmp/proj",
      }),
    );

    const project = getProject(store, "/tmp/proj");
    expect(project?.sessionActive).toBe(false);
  });
});

describe("evictStaleProjects", () => {
  test("evicts project inactive > maxAge", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({ _hook: "session-start", cwd: "/tmp/proj" }),
    );

    // Manually set lastEventTime to 25 hours ago
    const project = getProject(store, "/tmp/proj");
    if (project) project.lastEventTime = Date.now() - 25 * 60 * 60 * 1000;

    evictStaleProjects(store, 24 * 60 * 60 * 1000);
    expect(store.projects.size).toBe(0);
  });

  test("keeps project inactive < maxAge", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({ _hook: "session-start", cwd: "/tmp/proj" }),
    );

    evictStaleProjects(store, 24 * 60 * 60 * 1000);
    expect(store.projects.size).toBe(1);
  });
});

describe("serializeForPrompt", () => {
  test("formats projects and events", () => {
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

    // Add some events
    for (let i = 0; i < 5; i++) {
      updateState(
        store,
        makeEvent({
          _hook: "post-tool-use",
          cwd: "/tmp/proj-a",
          tool_name: "Bash",
          command: `npm test run-${i}`,
          tool_response: `${i} tests passed`,
        }),
      );
    }

    const result = serializeForPrompt(store);
    expect(result).toContain("Active Projects");
    expect(result).toContain("/tmp/proj-a");
    expect(result).toContain("/tmp/proj-b");
    expect(result).toContain("Recent Events");
  });
});

describe("event buffer", () => {
  test("FIFO drops oldest when exceeding max", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({ _hook: "session-start", cwd: "/tmp/proj" }),
    );

    // Push 55 important events
    for (let i = 0; i < 55; i++) {
      updateState(
        store,
        makeEvent({
          _hook: "post-tool-use",
          cwd: "/tmp/proj",
          tool_name: "Bash",
          command: `npm test batch-${i}`,
          tool_response: `result-${i}`,
        }),
      );
    }

    // 1 session-start + 55 post-tool-use = 56, capped at 50
    expect(store.events.length).toBeLessThanOrEqual(50);
  });

  test("preserves order", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({ _hook: "session-start", cwd: "/tmp/proj" }),
    );

    updateState(
      store,
      makeEvent({
        _hook: "post-tool-use",
        cwd: "/tmp/proj",
        tool_name: "Bash",
        command: "npm test first",
        tool_response: "first",
      }),
    );

    updateState(
      store,
      makeEvent({
        _hook: "post-tool-use",
        cwd: "/tmp/proj",
        tool_name: "Bash",
        command: "npm test second",
        tool_response: "second",
      }),
    );

    // Events should be in order: session-start, first, second
    const summaries = store.events.map((e) => e.summary);
    const firstIdx = summaries.findIndex((s) => s.includes("first"));
    const secondIdx = summaries.findIndex((s) => s.includes("second"));
    expect(firstIdx).toBeLessThan(secondIdx);
  });
});
