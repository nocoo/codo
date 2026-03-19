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
        last_assistant_message: "Done",
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
        last_assistant_message: "Built everything",
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

    // Important event (stop) should trigger LLM
    await processLine(
      JSON.stringify({
        _hook: "stop",
        session_id: "s1",
        hook_event_name: "stop",
        cwd: "/tmp",
        last_assistant_message: "Refactored auth",
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

    // Event 1: session-start (contextual, no LLM)
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

    // Event 3: stop (triggers LLM)
    await processLine(
      JSON.stringify({
        _hook: "stop",
        session_id: "s1",
        hook_event_name: "stop",
        cwd: "/tmp/proj",
        last_assistant_message: "All done",
      }),
      state,
      client,
    );

    capture.restore();

    // Should have emitted 3 actions:
    // session-start (fallback: "Session Started") + post-tool-use + stop
    expect(capture.lines.length).toBe(3);

    // State should have accumulated all events
    expect(state.events.length).toBe(3); // start + tool-use + stop
    expect(state.projects.size).toBe(1);
  });
});
