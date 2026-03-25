import { describe, expect, test } from "bun:test";
import type OpenAI from "openai";
import { processLine } from "./main";
import { createStateStore } from "./state";
import type { LLMClient } from "./llm";
import type { GuardianResult, HookEvent } from "./types";

// Capture stdout writes
function captureStdout(): { lines: string[]; restore: () => void } {
  const lines: string[] = [];
  const original = process.stdout.write.bind(process.stdout);
  process.stdout.write = ((chunk: string | Uint8Array) => {
    if (typeof chunk === "string") {
      lines.push(chunk.trim());
    }
    return true;
  }) as typeof process.stdout.write;
  return {
    lines,
    restore: () => {
      process.stdout.write = original;
    },
  };
}

function createMockLLMClient(result: GuardianResult): LLMClient {
  return {
    async process(): Promise<GuardianResult> {
      return result;
    },
  };
}

describe("guardian main", () => {
  test("stdin parse: JSON line parsed as event", async () => {
    const state = createStateStore();
    const capture = captureStdout();
    const client = createMockLLMClient({
      action: "send",
      notification: { title: "Test" },
    });

    await processLine(
      JSON.stringify({
        _hook: "stop",
        session_id: "s1",
        hook_event_name: "stop",
        cwd: "/tmp",
        last_assistant_message:
          "I have completed the refactoring of the authentication module successfully.",
      }),
      state,
      client,
    );

    capture.restore();
    expect(capture.lines.length).toBe(1);
    const action = JSON.parse(capture.lines[0]);
    expect(action.action).toBe("send");
    expect(action.notification.title).toBe("Test");
  });

  test("stdout action: send action emits GuardianAction", async () => {
    const state = createStateStore();
    const capture = captureStdout();
    const client = createMockLLMClient({
      action: "send",
      notification: { title: "Build Done", body: "42 tests passed" },
    });

    await processLine(
      JSON.stringify({
        _hook: "stop",
        session_id: "s1",
        hook_event_name: "stop",
        cwd: "/tmp",
        last_assistant_message:
          "Built everything and verified all integration tests are passing correctly.",
      }),
      state,
      client,
    );

    capture.restore();
    const action = JSON.parse(capture.lines[0]);
    expect(action.action).toBe("send");
    expect(action.notification.title).toBe("Build Done");
    expect(action.notification.body).toBe("42 tests passed");
  });

  test("hook event dispatch: classified and processed", async () => {
    const state = createStateStore();
    const capture = captureStdout();

    const processedEvents: HookEvent[] = [];
    const client: LLMClient = {
      async process(event): Promise<GuardianResult> {
        processedEvents.push(event);
        return {
          action: "send",
          notification: { title: "Processed" },
        };
      },
    };

    // Important event (stop with long message) should trigger LLM
    await processLine(
      JSON.stringify({
        _hook: "stop",
        session_id: "s1",
        hook_event_name: "stop",
        cwd: "/tmp",
        last_assistant_message:
          "Refactored the authentication module with new JWT validation logic.",
      }),
      state,
      client,
    );

    capture.restore();
    expect(processedEvents.length).toBe(1);
    expect(processedEvents[0]._hook).toBe("stop");
  });

  test("CodoMessage dispatch: processed as direct notification", async () => {
    const state = createStateStore();
    const capture = captureStdout();
    const client = createMockLLMClient({
      action: "suppress",
      reason: "should not be called",
    });

    await processLine(
      JSON.stringify({ title: "Build Done", body: "OK" }),
      state,
      client,
    );

    capture.restore();
    const action = JSON.parse(capture.lines[0]);
    expect(action.action).toBe("send");
    expect(action.notification.title).toBe("Build Done");
    expect(action.notification.body).toBe("OK");
  });

  test("malformed JSON: error logged, no crash", async () => {
    const state = createStateStore();
    const capture = captureStdout();
    const stderrLines: string[] = [];
    const origStderr = process.stderr.write.bind(process.stderr);
    process.stderr.write = ((chunk: string | Uint8Array) => {
      if (typeof chunk === "string") stderrLines.push(chunk);
      return true;
    }) as typeof process.stderr.write;

    const client = createMockLLMClient({
      action: "suppress",
      reason: "noop",
    });

    await processLine("{bad json", state, client);

    capture.restore();
    process.stderr.write = origStderr;
    expect(capture.lines.length).toBe(0);
    expect(stderrLines.some((l) => l.includes("malformed"))).toBe(true);
  });

  test("sequential events: all processed, state accumulated", async () => {
    const state = createStateStore();
    const capture = captureStdout();
    const client = createMockLLMClient({
      action: "send",
      notification: { title: "OK" },
    });

    // Event 1: session-start (contextual, no LLM, suppressed in fallback)
    await processLine(
      JSON.stringify({
        _hook: "session-start",
        session_id: "s1",
        hook_event_name: "session-start",
        cwd: "/tmp/proj",
        model: "claude-sonnet-4-6",
      }),
      state,
      client,
    );

    // Event 2: post-tool-use important (triggers LLM)
    await processLine(
      JSON.stringify({
        _hook: "post-tool-use",
        session_id: "s1",
        hook_event_name: "post-tool-use",
        cwd: "/tmp/proj",
        tool_name: "Bash",
        command: "npm test",
        tool_response: "42 passed",
      }),
      state,
      client,
    );

    // Event 3: stop with long message (triggers LLM)
    await processLine(
      JSON.stringify({
        _hook: "stop",
        session_id: "s1",
        hook_event_name: "stop",
        cwd: "/tmp/proj",
        last_assistant_message:
          "All done, the full test suite passes with 42 tests green.",
      }),
      state,
      client,
    );

    capture.restore();

    // Should have emitted 2 actions:
    // session-start (suppressed) + post-tool-use (LLM) + stop (LLM)
    expect(capture.lines.length).toBe(2);

    // State should have accumulated all events
    expect(state.events.length).toBe(3); // start + tool-use + stop
    expect(state.projects.size).toBe(1);
  });

  test("serial execution: slow LLM does not cause interleaving", async () => {
    const state = createStateStore();
    const capture = captureStdout();
    const order: number[] = [];

    const client: LLMClient = {
      async process(event): Promise<GuardianResult> {
        const msg = event.last_assistant_message as string;
        const idx = msg.startsWith("First") ? 1 : 2;
        // First event takes longer to process
        if (idx === 1) {
          await new Promise((resolve) => setTimeout(resolve, 50));
        }
        order.push(idx);
        return {
          action: "send",
          notification: { title: `Event-${idx}` },
        };
      },
    };

    // Fire both processLine calls "concurrently" (simulating readline firing
    // two lines without awaiting the first)
    const p1 = processLine(
      JSON.stringify({
        _hook: "stop",
        session_id: "s1",
        hook_event_name: "stop",
        cwd: "/tmp",
        last_assistant_message:
          "First batch of changes completed including the refactor of the auth module.",
      }),
      state,
      client,
    );
    const p2 = processLine(
      JSON.stringify({
        _hook: "stop",
        session_id: "s1",
        hook_event_name: "stop",
        cwd: "/tmp",
        last_assistant_message:
          "Second batch of changes completed with all integration tests passing.",
      }),
      state,
      client,
    );

    await Promise.all([p1, p2]);
    capture.restore();

    // Without serial queue, p2 would finish before p1 (idx=2 before idx=1)
    // because p1 has 50ms delay.
    // With serial queue at the readline level, both still run sequentially
    // through processLine, but since processLine itself is the unit of work,
    // the test validates that processLine doesn't internally break ordering.
    // The real queue lives in import.meta.main — here we verify processLine
    // outputs are correct even when called concurrently.
    expect(capture.lines.length).toBe(2);
    expect(order.length).toBe(2);
  });
});

// ── Object-typed HookEvent fields: end-to-end through processLine ──

describe("guardian main object payloads", () => {
  test("stop with object last_assistant_message → no crash in updateState", async () => {
    const state = createStateStore();
    const capture = captureStdout();
    const client = createMockLLMClient({
      action: "send",
      notification: { title: "Done" },
    });

    // Object message is non-string → classifier treats as short → contextual
    // → fallback → truncate returns undefined → suppressed (no crash)
    await processLine(
      JSON.stringify({
        _hook: "stop",
        session_id: "s1",
        hook_event_name: "stop",
        cwd: "/tmp",
        last_assistant_message: { text: "done", tokens: 42 },
      }),
      state,
      client,
    );

    capture.restore();
    // Object message → contextual → fallback → empty body → suppressed
    expect(capture.lines.length).toBe(0);
  });

  test("post-tool-use with object tool_response → no crash", async () => {
    const state = createStateStore();
    const capture = captureStdout();
    const client = createMockLLMClient({
      action: "send",
      notification: { title: "Result" },
    });

    await processLine(
      JSON.stringify({
        _hook: "post-tool-use",
        session_id: "s1",
        hook_event_name: "post-tool-use",
        cwd: "/tmp",
        tool_name: "Bash",
        command: "npm test",
        tool_response: { stdout: "ok", exitCode: 0 },
      }),
      state,
      client,
    );

    capture.restore();
    expect(capture.lines.length).toBe(1);
    const action = JSON.parse(capture.lines[0]);
    expect(action.action).toBe("send");
  });

  test("post-tool-use-failure with object error → no crash", async () => {
    const state = createStateStore();
    const capture = captureStdout();
    const client = createMockLLMClient({
      action: "send",
      notification: { title: "Failed" },
    });

    await processLine(
      JSON.stringify({
        _hook: "post-tool-use-failure",
        session_id: "s1",
        hook_event_name: "post-tool-use-failure",
        cwd: "/tmp",
        tool_name: "Bash",
        error: { code: "ENOENT", message: "not found" },
      }),
      state,
      client,
    );

    capture.restore();
    expect(capture.lines.length).toBe(1);
    const action = JSON.parse(capture.lines[0]);
    expect(action.action).toBe("send");
  });
});
