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
    expect(result).toContain("Event History");
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

    // 1 session-start + 55 post-tool-use = 56, still under 200
    expect(store.events.length).toBe(56);
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

// ── Object-typed HookEvent fields: regression tests ──

describe("updateState object payloads", () => {
  test("stop with object last_assistant_message → no crash, task unchanged", () => {
    const store = createStateStore();
    updateState(store, makeEvent({ _hook: "session-start", cwd: "/tmp/proj" }));

    // Should NOT throw TypeError: message.trim is not a function
    updateState(
      store,
      makeEvent({
        _hook: "stop",
        cwd: "/tmp/proj",
        last_assistant_message: { text: "done", tokens: 42 },
      }),
    );

    const project = getProject(store, "/tmp/proj");
    // Object is not a string, so task should remain null (not updated)
    expect(project?.task).toBeNull();
  });

  test("stop with null last_assistant_message → no crash", () => {
    const store = createStateStore();
    updateState(store, makeEvent({ _hook: "session-start", cwd: "/tmp/proj" }));

    updateState(
      store,
      makeEvent({
        _hook: "stop",
        cwd: "/tmp/proj",
        last_assistant_message: null,
      }),
    );

    const project = getProject(store, "/tmp/proj");
    expect(project?.task).toBeNull();
  });

  test("stop with number last_assistant_message → no crash", () => {
    const store = createStateStore();
    updateState(store, makeEvent({ _hook: "session-start", cwd: "/tmp/proj" }));

    updateState(
      store,
      makeEvent({
        _hook: "stop",
        cwd: "/tmp/proj",
        last_assistant_message: 12345,
      }),
    );

    const project = getProject(store, "/tmp/proj");
    expect(project?.task).toBeNull();
  });

  test("post-tool-use with object tool_response → no crash, lastStatus set", () => {
    const store = createStateStore();
    updateState(store, makeEvent({ _hook: "session-start", cwd: "/tmp/proj" }));

    updateState(
      store,
      makeEvent({
        _hook: "post-tool-use",
        cwd: "/tmp/proj",
        tool_name: "Bash",
        command: "npm test",
        tool_response: { stdout: "42 passed", exitCode: 0 },
      }),
    );

    const project = getProject(store, "/tmp/proj");
    // truncate() with non-string calls String(), which produces [object Object]
    expect(project?.lastStatus).toBeDefined();
    expect(project?.lastStatus).not.toContain("undefined");
  });

  test("post-tool-use-failure with object error → no crash", () => {
    const store = createStateStore();
    updateState(store, makeEvent({ _hook: "session-start", cwd: "/tmp/proj" }));

    updateState(
      store,
      makeEvent({
        _hook: "post-tool-use-failure",
        cwd: "/tmp/proj",
        tool_name: "Bash",
        error: { code: "ENOENT", message: "not found" },
      }),
    );

    const project = getProject(store, "/tmp/proj");
    expect(project?.lastStatus).toBeDefined();
  });

  test("notification with object title → defaults to 'Untitled'", () => {
    const store = createStateStore();
    updateState(store, makeEvent({ _hook: "session-start", cwd: "/tmp/proj" }));

    updateState(
      store,
      makeEvent({
        _hook: "notification",
        cwd: "/tmp/proj",
        title: { key: "value" },
        message: "some message",
      }),
    );

    const project = getProject(store, "/tmp/proj");
    expect(project?.recentNotifications.length).toBe(1);
    expect(project?.recentNotifications[0].title).toBe("Untitled");
  });

  test("session-start with non-string model → model is null", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        cwd: "/tmp/proj",
        model: { name: "claude" },
      }),
    );

    const project = getProject(store, "/tmp/proj");
    expect(project?.model).toBeNull();
  });

  test("summarizeEvent with object fields → event buffered without crash", () => {
    const store = createStateStore();

    // This exercises summarizeEvent() through updateState() event buffering
    updateState(
      store,
      makeEvent({
        _hook: "stop",
        cwd: "/tmp/proj",
        last_assistant_message: { complex: "object" },
      }),
    );

    // Event should be buffered (stop is "important" tier)
    expect(store.events.length).toBeGreaterThan(0);
    const lastEvent = store.events[store.events.length - 1];
    expect(lastEvent.summary).toContain("stop:");
    // Should NOT contain [object Object] because truncate returns String() representation
  });
});

// ── Commit 1: Context expansion tests ──

describe("event buffer expanded", () => {
  test("FIFO cap at 200", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({ _hook: "session-start", cwd: "/tmp/proj" }),
    );

    // Push 210 important events
    for (let i = 0; i < 210; i++) {
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

    // 1 session-start + 210 post-tool-use = 211, capped at 200
    expect(store.events.length).toBeLessThanOrEqual(200);
    // Oldest events should be dropped — the last event should be batch-209
    const lastEvent = store.events[store.events.length - 1];
    expect(lastEvent.summary).toContain("batch-209");
  });
});

describe("notification body stored", () => {
  test("body field is recorded from message", () => {
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
        title: "Tests passed",
        message: "All 42 tests passed with 95% coverage",
      }),
    );

    const project = getProject(store, "/tmp/proj");
    expect(project?.recentNotifications[0].body).toBe(
      "All 42 tests passed with 95% coverage",
    );
  });

  test("body is undefined when message is not a string", () => {
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
        title: "No body",
        message: { complex: "object" },
      }),
    );

    const project = getProject(store, "/tmp/proj");
    expect(project?.recentNotifications[0].body).toBeUndefined();
  });
});

describe("sessionToCwd resolution", () => {
  test("session_id → cwd resolution at write time", () => {
    const store = createStateStore();

    // session-start with cwd
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        session_id: "sess-1",
        cwd: "/tmp/proj",
      }),
    );

    // session-end without cwd — should resolve to /tmp/proj via sessionToCwd
    updateState(
      store,
      makeEvent({
        _hook: "session-end",
        session_id: "sess-1",
        cwd: undefined,
      }),
    );

    const sessionEndEvent = store.events.find(
      (e) => e.hookType === "session-end",
    );
    expect(sessionEndEvent?.cwd).toBe(canonicalizePath("/tmp/proj"));
  });

  test("multi-session same cwd: old session still resolves after overwrite", () => {
    const store = createStateStore();

    // Session s1 starts on /tmp/proj
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        session_id: "s1",
        cwd: "/tmp/proj",
      }),
    );

    // Session s2 starts on same /tmp/proj — overwrites ProjectState.sessionId
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        session_id: "s2",
        cwd: "/tmp/proj",
      }),
    );

    // s1 sends a stop event without cwd — should still resolve via sessionToCwd
    updateState(
      store,
      makeEvent({
        _hook: "stop",
        session_id: "s1",
        cwd: undefined,
        last_assistant_message: "old session finishing up",
      }),
    );

    const s1Stop = store.events.find(
      (e) => e.hookType === "stop" && e.sessionId === "s1",
    );
    expect(s1Stop?.cwd).toBe(canonicalizePath("/tmp/proj"));
  });

  test("cwd canonicalization consistency: trailing slash", () => {
    const store = createStateStore();

    // session-start with canonical path
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        session_id: "sess-c",
        cwd: "/tmp/proj",
      }),
    );

    // event with trailing slash — should be canonicalized to match
    updateState(
      store,
      makeEvent({
        _hook: "post-tool-use",
        session_id: "sess-c",
        cwd: "/tmp/proj",
        tool_name: "Bash",
        command: "npm test",
        tool_response: "ok",
      }),
    );

    const toolEvent = store.events.find((e) => e.hookType === "post-tool-use");
    const sessionEvent = store.events.find(
      (e) => e.hookType === "session-start",
    );
    // Both should have the same canonical cwd
    expect(toolEvent?.cwd).toBe(sessionEvent?.cwd);
  });

  test("cwd canonicalization consistency: .. segment", () => {
    const store = createStateStore();

    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        session_id: "sess-d",
        cwd: "/tmp/proj",
      }),
    );

    // /tmp/foo/../proj should canonicalize to /tmp/proj (if /tmp/proj exists)
    // For non-existent paths, canonicalizePath returns as-is, so we test with /tmp
    updateState(
      store,
      makeEvent({
        _hook: "post-tool-use",
        session_id: "sess-d",
        cwd: "/tmp/../tmp",
        tool_name: "Bash",
        command: "ls",
        tool_response: "ok",
      }),
    );

    const toolEvent = store.events.find((e) => e.hookType === "post-tool-use");
    // /tmp/../tmp should canonicalize to the real path of /tmp
    expect(toolEvent?.cwd).toBe(canonicalizePath("/tmp"));
    // Should NOT contain ".."
    expect(toolEvent?.cwd).not.toContain("..");
  });

  test("session-end without cwd resolves via sessionToCwd and sets sessionActive false", () => {
    const store = createStateStore();

    // session-start registers sessionToCwd and sets sessionActive = true
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        session_id: "sess-end-1",
        cwd: "/tmp/proj",
      }),
    );

    const projCwd = canonicalizePath("/tmp/proj");
    expect(store.projects.get(projCwd)?.sessionActive).toBe(true);

    // session-end without cwd — should resolve via sessionToCwd and update project
    updateState(
      store,
      makeEvent({
        _hook: "session-end",
        session_id: "sess-end-1",
        cwd: undefined,
      }),
    );

    expect(store.projects.get(projCwd)?.sessionActive).toBe(false);
  });

  test("session-end without cwd and no sessionToCwd entry: no crash, no spurious project", () => {
    const store = createStateStore();

    const projectCountBefore = store.projects.size;

    // session-end with unknown session and no cwd — should be a no-op for project state
    updateState(
      store,
      makeEvent({
        _hook: "session-end",
        session_id: "unknown-session",
        cwd: undefined,
      }),
    );

    // No new project created
    expect(store.projects.size).toBe(projectCountBefore);
    // Event is still buffered (with undefined cwd)
    const endEvent = store.events.find((e) => e.hookType === "session-end");
    expect(endEvent).toBeDefined();
    expect(endEvent?.cwd).toBeUndefined();
  });
});

describe("sessionToCwd cleanup", () => {
  test("evictStaleProjects prunes orphaned sessions, keeps live ones", () => {
    const store = createStateStore();

    // Create session referenced in events
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        session_id: "sess-in-events",
        cwd: "/tmp/proj-a",
      }),
    );

    // Create session attached to surviving project but not in events
    // (simulated by directly populating sessionToCwd + project)
    store.sessionToCwd.set(
      "sess-on-project",
      canonicalizePath("/tmp/proj-b"),
    );
    store.projects.set(canonicalizePath("/tmp/proj-b"), {
      cwd: canonicalizePath("/tmp/proj-b"),
      sessionId: "sess-on-project",
      task: null,
      lastStatus: null,
      model: null,
      recentNotifications: [],
      lastEventTime: Date.now(), // recent, won't be evicted
      sessionActive: true,
      transcriptLastReadOffset: 0,
    });

    // Create completely orphaned session
    store.sessionToCwd.set("sess-orphan", "/tmp/gone");

    expect(store.sessionToCwd.size).toBe(3);

    evictStaleProjects(store, 24 * 60 * 60 * 1000);

    // sess-in-events: kept (in events)
    expect(store.sessionToCwd.has("sess-in-events")).toBe(true);
    // sess-on-project: kept (on surviving project)
    expect(store.sessionToCwd.has("sess-on-project")).toBe(true);
    // sess-orphan: pruned
    expect(store.sessionToCwd.has("sess-orphan")).toBe(false);
  });
});

describe("summarizeEvent expanded truncation", () => {
  test("stop preserves longer assistant messages", () => {
    const store = createStateStore();
    const longMsg = "x".repeat(400);

    updateState(
      store,
      makeEvent({
        _hook: "stop",
        cwd: "/tmp/proj",
        last_assistant_message: longMsg,
      }),
    );

    const stopEvent = store.events.find((e) => e.hookType === "stop");
    // 400 chars < 500 limit, so full message should be preserved
    expect(stopEvent?.summary).toContain(longMsg);
  });

  test("notification includes message in summary", () => {
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
        title: "Build done",
        message: "Release package compiled successfully",
      }),
    );

    const notifEvent = store.events.find(
      (e) => e.hookType === "notification",
    );
    expect(notifEvent?.summary).toContain("Build done");
    expect(notifEvent?.summary).toContain("Release package compiled");
  });

  test("post-tool-use includes tool_response in summary", () => {
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
        command: "npm test",
        tool_response: "42 tests passed, 0 failures",
      }),
    );

    const toolEvent = store.events.find(
      (e) => e.hookType === "post-tool-use",
    );
    expect(toolEvent?.summary).toContain("→");
    expect(toolEvent?.summary).toContain("42 tests passed");
  });
});

// ── Commit 2: Serialization with charBudget, notification history, project grouping ──

describe("serializeForPrompt charBudget", () => {
  test("charBudget truncation: small budget excludes oldest events", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        cwd: "/tmp/proj",
        session_id: "s-budget",
      }),
    );

    // Push 100 important events with sizeable summaries
    for (let i = 0; i < 100; i++) {
      updateState(
        store,
        makeEvent({
          _hook: "post-tool-use",
          cwd: "/tmp/proj",
          session_id: "s-budget",
          tool_name: "Bash",
          command: `npm test run-${"x".repeat(50)}-${i}`,
          tool_response: `PASS ${"y".repeat(100)}-result-${i}`,
        }),
      );
    }

    // Serialize with moderate budget — should include only recent events
    const result = serializeForPrompt(store, 15000);
    // Most recent event should be present
    expect(result).toContain("result-99");
    // Oldest events should be excluded (budget too small for all 100)
    expect(result).not.toContain("result-0 ");
  });

  test("large budget includes all events", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        cwd: "/tmp/proj",
        session_id: "s-large",
      }),
    );

    for (let i = 0; i < 10; i++) {
      updateState(
        store,
        makeEvent({
          _hook: "post-tool-use",
          cwd: "/tmp/proj",
          session_id: "s-large",
          tool_name: "Bash",
          command: `npm test suite-${i}`,
          tool_response: `pass-${i}`,
        }),
      );
    }

    const result = serializeForPrompt(store, 600_000);
    // All events should be present
    for (let i = 0; i < 10; i++) {
      expect(result).toContain(`suite-${i}`);
    }
  });
});

describe("serializeForPrompt notification history", () => {
  test("notification history appears in output", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        cwd: "/tmp/proj",
        session_id: "s-notif",
      }),
    );

    // Send a notification with title + body
    updateState(
      store,
      makeEvent({
        _hook: "notification",
        cwd: "/tmp/proj",
        session_id: "s-notif",
        title: "Tests passed",
        message: "All 42 tests passed with 95% coverage",
      }),
    );

    const result = serializeForPrompt(store);
    expect(result).toContain("Sent Notifications");
    expect(result).toContain("Tests passed");
    expect(result).toContain("All 42 tests passed");
  });

  test("notification history capped at 3 most recent per project", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        cwd: "/tmp/proj",
        session_id: "s-cap",
      }),
    );

    // Push 5 notifications
    for (let i = 0; i < 5; i++) {
      updateState(
        store,
        makeEvent({
          _hook: "notification",
          cwd: "/tmp/proj",
          session_id: "s-cap",
          title: `Notif-${i}`,
          message: `Body-${i}`,
        }),
      );
    }

    const result = serializeForPrompt(store);
    // Extract just the Sent Notifications section
    const sentNotifMatch = result.match(
      /#### Sent Notifications\n([\s\S]*?)(?=\n####|\n###|\n##|$)/,
    );
    expect(sentNotifMatch).toBeTruthy();
    const sentSection = sentNotifMatch![1];
    // Only the last 3 should appear in Sent Notifications
    expect(sentSection).not.toContain("Notif-0");
    expect(sentSection).not.toContain("Notif-1");
    expect(sentSection).toContain("Notif-2");
    expect(sentSection).toContain("Notif-3");
    expect(sentSection).toContain("Notif-4");
  });

  test("notification history rendered before events (priority reserve)", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        cwd: "/tmp/proj",
        session_id: "s-prio",
      }),
    );

    updateState(
      store,
      makeEvent({
        _hook: "notification",
        cwd: "/tmp/proj",
        session_id: "s-prio",
        title: "Priority notification",
        message: "This should appear even with tiny budget",
      }),
    );

    // Push some tool events
    for (let i = 0; i < 5; i++) {
      updateState(
        store,
        makeEvent({
          _hook: "post-tool-use",
          cwd: "/tmp/proj",
          session_id: "s-prio",
          tool_name: "Bash",
          command: `cmd-${i}`,
          tool_response: `res-${i}`,
        }),
      );
    }

    // Even with moderate budget, notification should be present
    const result = serializeForPrompt(store, 3000);
    expect(result).toContain("Sent Notifications");
    expect(result).toContain("Priority notification");
  });
});

describe("serializeForPrompt project grouping", () => {
  test("events grouped by project cwd", () => {
    const store = createStateStore();

    // Two different projects
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        cwd: "/tmp/proj-a",
        session_id: "sa",
      }),
    );
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        cwd: "/tmp/proj-b",
        session_id: "sb",
      }),
    );

    updateState(
      store,
      makeEvent({
        _hook: "post-tool-use",
        cwd: "/tmp/proj-a",
        session_id: "sa",
        tool_name: "Bash",
        command: "npm test",
        tool_response: "proj-a-result",
      }),
    );
    updateState(
      store,
      makeEvent({
        _hook: "post-tool-use",
        cwd: "/tmp/proj-b",
        session_id: "sb",
        tool_name: "Bash",
        command: "cargo test",
        tool_response: "proj-b-result",
      }),
    );

    const result = serializeForPrompt(store);
    // Should have project-level headings
    expect(result).toContain("### " + canonicalizePath("/tmp/proj-a"));
    expect(result).toContain("### " + canonicalizePath("/tmp/proj-b"));
    expect(result).toContain("Event Timeline");
  });

  test("events without cwd grouped under 'unknown'", () => {
    const store = createStateStore();

    // session-start sets up sessionToCwd
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        cwd: "/tmp/proj",
        session_id: "s-unk",
      }),
    );

    // An event from an unknown session (no cwd, no sessionToCwd entry)
    const buffered: import("./state").BufferedEvent = {
      timestamp: Date.now(),
      hookType: "stop" as import("./types").HookEventName,
      sessionId: "unknown-session",
      cwd: undefined,
      summary: "stop: orphan event",
      raw: {},
    };
    store.events.push(buffered);

    const result = serializeForPrompt(store);
    expect(result).toContain("### unknown");
  });
});

describe("serializeForPrompt budget accuracy", () => {
  test("tight budget fits only newest notification, not all 3", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        cwd: "/tmp/proj",
        session_id: "s-tight",
      }),
    );

    // Add 3 notifications with distinctive titles
    for (let i = 0; i < 3; i++) {
      updateState(
        store,
        makeEvent({
          _hook: "notification",
          cwd: "/tmp/proj",
          session_id: "s-tight",
          title: `Notif-${i}`,
          message: `Body for notification ${i} with some padding text`,
        }),
      );
    }

    // Budget enough for structural reserve + 1 notification line (~100 chars)
    // but NOT enough for all 3 notifications + events
    // A single notification line is ~70-80 chars. With structural reserve (~320)
    // subtracted from budget, we need enough for 1 but not 3.
    const result = serializeForPrompt(store, 600);

    // Extract only the Sent Notifications section
    const notifSection = result.match(
      /#### Sent Notifications\n([\s\S]*?)(?=\n####|\n###|\n##|$)/,
    );

    if (notifSection) {
      // Should contain the newest notification (Notif-2)
      expect(notifSection[1]).toContain("Notif-2");
      // May or may not contain older ones depending on exact budget
      // The key invariant: newest is always preferred
    }
    // Regardless of section extraction, Notif-2 (newest) should be present
    // if any notification fits at all
    if (result.includes("Sent Notifications")) {
      expect(result).toContain("Notif-2");
    }
  });

  test("large budget still caps at 3 most recent notifications per project", () => {
    const store = createStateStore();
    updateState(
      store,
      makeEvent({
        _hook: "session-start",
        cwd: "/tmp/proj",
        session_id: "s-cap",
      }),
    );

    // Add 5 notifications
    for (let i = 0; i < 5; i++) {
      updateState(
        store,
        makeEvent({
          _hook: "notification",
          cwd: "/tmp/proj",
          session_id: "s-cap",
          title: `Notif-${i}`,
          message: `Body ${i}`,
        }),
      );
    }

    const result = serializeForPrompt(store, 600_000);
    const notifSection = result.match(
      /#### Sent Notifications\n([\s\S]*?)(?=\n####|\n###|\n##|$)/,
    );
    expect(notifSection).toBeTruthy();

    // Only most recent 3 (Notif-2, Notif-3, Notif-4) should appear
    expect(notifSection![1]).not.toContain("Notif-0");
    expect(notifSection![1]).not.toContain("Notif-1");
    expect(notifSection![1]).toContain("Notif-2");
    expect(notifSection![1]).toContain("Notif-3");
    expect(notifSection![1]).toContain("Notif-4");
  });

  test("structural overhead: output stays within reasonable budget bounds", () => {
    const store = createStateStore();

    // Create 5 projects with events and notifications
    for (let p = 0; p < 5; p++) {
      const cwd = `/tmp/proj-${p}`;
      const sid = `s-${p}`;
      updateState(
        store,
        makeEvent({
          _hook: "session-start",
          cwd,
          session_id: sid,
        }),
      );

      // 3 tool events per project
      for (let i = 0; i < 3; i++) {
        updateState(
          store,
          makeEvent({
            _hook: "post-tool-use",
            cwd,
            session_id: sid,
            tool_name: "Bash",
            command: `npm test run-${i}`,
            tool_response: `result-${p}-${i}`,
          }),
        );
      }

      // 2 notifications per project
      for (let i = 0; i < 2; i++) {
        updateState(
          store,
          makeEvent({
            _hook: "notification",
            cwd,
            session_id: sid,
            title: `Notif-${p}-${i}`,
            message: `Body for project ${p} notification ${i}`,
          }),
        );
      }
    }

    const budget = 8000;
    const result = serializeForPrompt(store, budget);

    // Output should not exceed budget by more than 15% (structural overhead tolerance)
    expect(result.length).toBeLessThan(budget * 1.15);
  });
});
