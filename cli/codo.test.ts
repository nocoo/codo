import { describe, expect, test } from "bun:test";
import {
  TEMPLATES,
  applyTemplate,
  parseArgs,
  parseStdin,
} from "./codo.ts";

// MARK: - parseArgs

describe("parseArgs", () => {
  test("title only", () => {
    const result = parseArgs(["Hello"]);
    expect(result).toEqual({
      message: { title: "Hello", body: undefined, sound: "default" },
      template: undefined,
    });
  });

  test("title and body", () => {
    const result = parseArgs(["Hello", "World"]);
    expect(result).toEqual({
      message: { title: "Hello", body: "World", sound: "default" },
      template: undefined,
    });
  });

  test("silent flag", () => {
    const result = parseArgs(["Hello", "--silent"]);
    expect(result).toEqual({
      message: { title: "Hello", body: undefined, sound: "none" },
      template: undefined,
    });
  });

  test("title body and silent", () => {
    const result = parseArgs(["Hello", "World", "--silent"]);
    expect(result).toEqual({
      message: { title: "Hello", body: "World", sound: "none" },
      template: undefined,
    });
  });

  test("no positional args returns null", () => {
    const result = parseArgs([]);
    expect(result).toBeNull();
  });

  test("only flags returns null", () => {
    const result = parseArgs(["--silent"]);
    expect(result).toBeNull();
  });

  test("empty title returns error", () => {
    const result = parseArgs([""]);
    expect(result).toEqual({ error: "title is required" });
  });

  test("whitespace title returns error", () => {
    const result = parseArgs(["   "]);
    expect(result).toEqual({ error: "title is required" });
  });

  test("unknown flags ignored", () => {
    const result = parseArgs(["Hello", "--unknown"]);
    expect(result).toEqual({
      message: { title: "Hello", body: undefined, sound: "default" },
      template: undefined,
    });
  });

  // Template flag tests
  test("--template success", () => {
    const result = parseArgs(["Build Done", "--template", "success"]);
    expect(result).not.toBeNull();
    if (result && "message" in result) {
      expect(result.message.subtitle).toBe("✅ Success");
      expect(result.message.sound).toBe("default");
      expect(result.template).toBe("success");
    }
  });

  test("--template error", () => {
    const result = parseArgs(["Failed", "--template", "error"]);
    expect(result).not.toBeNull();
    if (result && "message" in result) {
      expect(result.message.subtitle).toBe("❌ Error");
      expect(result.message.sound).toBe("default");
    }
  });

  test("--template info sets silent sound", () => {
    const result = parseArgs(["Status", "--template", "info"]);
    expect(result).not.toBeNull();
    if (result && "message" in result) {
      expect(result.message.subtitle).toBe("ℹ️ Info");
      expect(result.message.sound).toBe("none");
    }
  });

  test("--template unknown returns error", () => {
    const result = parseArgs(["Title", "--template", "bogus"]);
    expect(result).toEqual({ error: "unknown template: bogus" });
  });

  test("--template at end of argv returns error", () => {
    const result = parseArgs(["Title", "--template"]);
    expect(result).toEqual({ error: "--template requires a value" });
  });

  // Subtitle flag tests
  test("--subtitle sets subtitle", () => {
    const result = parseArgs(["Title", "--subtitle", "Custom Sub"]);
    expect(result).not.toBeNull();
    if (result && "message" in result) {
      expect(result.message.subtitle).toBe("Custom Sub");
    }
  });

  test("--subtitle overrides template subtitle", () => {
    const result = parseArgs([
      "Title",
      "--template",
      "success",
      "--subtitle",
      "My Sub",
    ]);
    expect(result).not.toBeNull();
    if (result && "message" in result) {
      expect(result.message.subtitle).toBe("My Sub");
    }
  });

  test("--subtitle at end of argv returns error", () => {
    const result = parseArgs(["Title", "--subtitle"]);
    expect(result).toEqual({ error: "--subtitle requires a value" });
  });

  test("--subtitle whitespace normalized to omitted", () => {
    const result = parseArgs(["Title", "--subtitle", "  "]);
    expect(result).not.toBeNull();
    if (result && "message" in result) {
      expect(result.message.subtitle).toBeUndefined();
    }
  });

  // Thread flag tests
  test("--thread sets threadId", () => {
    const result = parseArgs(["Title", "--thread", "build"]);
    expect(result).not.toBeNull();
    if (result && "message" in result) {
      expect(result.message.threadId).toBe("build");
    }
  });

  test("--thread at end of argv returns error", () => {
    const result = parseArgs(["Title", "--thread"]);
    expect(result).toEqual({ error: "--thread requires a value" });
  });

  test("--thread followed by flag returns error", () => {
    const result = parseArgs(["Title", "--thread", "--silent"]);
    expect(result).toEqual({ error: "--thread requires a value" });
  });

  test("--template followed by flag returns error", () => {
    const result = parseArgs(["Title", "--template", "--silent"]);
    expect(result).toEqual({ error: "--template requires a value" });
  });

  test("--subtitle followed by flag returns error", () => {
    const result = parseArgs(["Title", "--subtitle", "--thread"]);
    expect(result).toEqual({ error: "--subtitle requires a value" });
  });

  test("--thread whitespace normalized to omitted", () => {
    const result = parseArgs(["Title", "--thread", ""]);
    expect(result).not.toBeNull();
    if (result && "message" in result) {
      expect(result.message.threadId).toBeUndefined();
    }
  });

  // --silent overrides template sound
  test("--silent overrides template sound", () => {
    const result = parseArgs([
      "Title",
      "--template",
      "success",
      "--silent",
    ]);
    expect(result).not.toBeNull();
    if (result && "message" in result) {
      expect(result.message.sound).toBe("none");
      expect(result.message.subtitle).toBe("✅ Success");
    }
  });

  // Mixed flags and positional in any order
  test("mixed positional and flags", () => {
    const result = parseArgs([
      "--template",
      "deploy",
      "Deploying",
      "--thread",
      "v1.2",
      "to prod",
      "--silent",
    ]);
    expect(result).not.toBeNull();
    if (result && "message" in result) {
      expect(result.message.title).toBe("Deploying");
      expect(result.message.body).toBe("to prod");
      expect(result.message.subtitle).toBe("🚀 Deploy");
      expect(result.message.sound).toBe("none");
      expect(result.message.threadId).toBe("v1.2");
    }
  });
});

// MARK: - parseStdin

describe("parseStdin", () => {
  test("valid json with title", () => {
    const result = parseStdin('{"title":"Hello"}');
    expect(result).toEqual({ message: { title: "Hello" } });
  });

  test("valid json with all fields", () => {
    const result = parseStdin(
      '{"title":"Hello","body":"World","sound":"none"}',
    );
    expect(result).toEqual({
      message: { title: "Hello", body: "World", sound: "none" },
    });
  });

  test("empty input", () => {
    const result = parseStdin("");
    expect(result).toEqual({ error: "empty input" });
  });

  test("whitespace input", () => {
    const result = parseStdin("   \n  ");
    expect(result).toEqual({ error: "empty input" });
  });

  test("invalid json", () => {
    const result = parseStdin("not json");
    expect(result).toEqual({ error: "invalid json" });
  });

  test("json array", () => {
    const result = parseStdin('[{"title":"Hello"}]');
    expect(result).toEqual({ error: "invalid json" });
  });

  test("missing title", () => {
    const result = parseStdin('{"body":"World"}');
    expect(result).toEqual({ error: "title is required" });
  });

  test("empty title", () => {
    const result = parseStdin('{"title":""}');
    expect(result).toEqual({ error: "title is required" });
  });

  test("whitespace title", () => {
    const result = parseStdin('{"title":"   "}');
    expect(result).toEqual({ error: "title is required" });
  });

  test("title is number", () => {
    const result = parseStdin('{"title":42}');
    expect(result).toEqual({ error: "title is required" });
  });

  test("extra whitespace around json", () => {
    const result = parseStdin('  {"title":"Hello"}  \n');
    expect(result).toEqual({ message: { title: "Hello" } });
  });

  test("ignores extra fields", () => {
    const result = parseStdin('{"title":"Hello","extra":"ignored"}');
    expect(result).toEqual({ message: { title: "Hello" } });
  });

  // New fields: subtitle and threadId
  test("subtitle and threadId parsed", () => {
    const result = parseStdin(
      '{"title":"T","subtitle":"✅ Success","threadId":"build"}',
    );
    expect(result).toEqual({
      message: { title: "T", subtitle: "✅ Success", threadId: "build" },
    });
  });

  test("empty subtitle normalized to omitted", () => {
    const result = parseStdin('{"title":"T","subtitle":""}');
    expect(result).toEqual({ message: { title: "T" } });
  });

  test("whitespace subtitle normalized to omitted", () => {
    const result = parseStdin('{"title":"T","subtitle":"  "}');
    expect(result).toEqual({ message: { title: "T" } });
  });

  test("empty threadId normalized to omitted", () => {
    const result = parseStdin('{"title":"T","threadId":""}');
    expect(result).toEqual({ message: { title: "T" } });
  });

  test("whitespace threadId normalized to omitted", () => {
    const result = parseStdin('{"title":"T","threadId":"  "}');
    expect(result).toEqual({ message: { title: "T" } });
  });

  test("template key in stdin silently ignored", () => {
    const result = parseStdin('{"title":"T","template":"success"}');
    expect(result).toEqual({ message: { title: "T" } });
  });
});

// MARK: - applyTemplate

describe("applyTemplate", () => {
  test("all 8 templates produce correct defaults", () => {
    const expected: Record<string, { subtitle: string; sound: string }> = {
      success: { subtitle: "✅ Success", sound: "default" },
      error: { subtitle: "❌ Error", sound: "default" },
      warning: { subtitle: "⚠️ Warning", sound: "default" },
      info: { subtitle: "ℹ️ Info", sound: "none" },
      progress: { subtitle: "🔄 In Progress", sound: "none" },
      question: { subtitle: "❓ Action Needed", sound: "default" },
      deploy: { subtitle: "🚀 Deploy", sound: "default" },
      review: { subtitle: "👀 Review", sound: "default" },
    };

    for (const [name, exp] of Object.entries(expected)) {
      const result = applyTemplate({ title: "T" }, name);
      expect("message" in result).toBe(true);
      if ("message" in result) {
        expect(result.message.subtitle).toBe(exp.subtitle);
        expect(result.message.sound).toBe(exp.sound);
      }
    }
  });

  test("unknown template returns error", () => {
    const result = applyTemplate({ title: "T" }, "nonexistent");
    expect(result).toEqual({ error: "unknown template: nonexistent" });
  });

  test("explicit subtitle wins over template", () => {
    const result = applyTemplate(
      { title: "T", subtitle: "Custom" },
      "success",
    );
    expect("message" in result).toBe(true);
    if ("message" in result) {
      expect(result.message.subtitle).toBe("Custom");
    }
  });

  test("explicit sound wins over template", () => {
    const result = applyTemplate({ title: "T", sound: "none" }, "success");
    expect("message" in result).toBe(true);
    if ("message" in result) {
      expect(result.message.sound).toBe("none");
    }
  });

  test("template never sets threadId", () => {
    for (const name of Object.keys(TEMPLATES)) {
      const result = applyTemplate({ title: "T" }, name);
      expect("message" in result).toBe(true);
      if ("message" in result) {
        expect(result.message.threadId).toBeUndefined();
      }
    }
  });
});

// MARK: - CLI process tests

describe("cli process", () => {
  const cliPath = `${import.meta.dir}/codo.ts`;

  test("--help exits 0", async () => {
    const proc = Bun.spawn(["bun", cliPath, "--help"], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const exitCode = await proc.exited;
    const stderr = await new Response(proc.stderr).text();
    const stdout = await new Response(proc.stdout).text();
    expect(exitCode).toBe(0);
    expect(stdout).toBe("");
    expect(stderr).toContain("Usage:");
    expect(stderr).toContain("--template");
    expect(stderr).toContain("--subtitle");
    expect(stderr).toContain("--thread");
  });

  test("--version exits 0", async () => {
    const proc = Bun.spawn(["bun", cliPath, "--version"], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const exitCode = await proc.exited;
    const stderr = await new Response(proc.stderr).text();
    const stdout = await new Response(proc.stdout).text();
    expect(exitCode).toBe(0);
    expect(stdout).toBe("");
    expect(stderr).toContain("codo 0.1.0");
  });

  test("no args with empty stdin exits 1", async () => {
    const proc = Bun.spawn(["bun", cliPath], {
      stdout: "pipe",
      stderr: "pipe",
      stdin: new Blob([""]),
    });
    const exitCode = await proc.exited;
    const stderr = await new Response(proc.stderr).text();
    const stdout = await new Response(proc.stdout).text();
    expect(exitCode).toBe(1);
    expect(stdout).toBe("");
    expect(stderr).toContain("empty input");
  });

  test("title arg but daemon not running exits 2", async () => {
    const proc = Bun.spawn(["bun", cliPath, "Test"], {
      stdout: "pipe",
      stderr: "pipe",
      env: {
        ...process.env,
        HOME: "/tmp/codo-test-nonexistent",
      },
    });
    const exitCode = await proc.exited;
    const stderr = await new Response(proc.stderr).text();
    const stdout = await new Response(proc.stdout).text();
    expect(exitCode).toBe(2);
    expect(stdout).toBe("");
    expect(stderr).toContain("daemon not running");
  });

  test("stdin json but daemon not running exits 2", async () => {
    const proc = Bun.spawn(["bun", cliPath], {
      stdout: "pipe",
      stderr: "pipe",
      stdin: new Blob(['{"title":"Test"}']),
      env: {
        ...process.env,
        HOME: "/tmp/codo-test-nonexistent",
      },
    });
    const exitCode = await proc.exited;
    const stderr = await new Response(proc.stderr).text();
    const stdout = await new Response(proc.stdout).text();
    expect(exitCode).toBe(2);
    expect(stdout).toBe("");
    expect(stderr).toContain("daemon not running");
  });

  test("empty title arg exits 1", async () => {
    const proc = Bun.spawn(["bun", cliPath, ""], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const exitCode = await proc.exited;
    const stderr = await new Response(proc.stderr).text();
    const stdout = await new Response(proc.stdout).text();
    expect(exitCode).toBe(1);
    expect(stdout).toBe("");
    expect(stderr).toContain("title is required");
  });

  test("invalid stdin json exits 1", async () => {
    const proc = Bun.spawn(["bun", cliPath], {
      stdout: "pipe",
      stderr: "pipe",
      stdin: new Blob(["not json at all"]),
    });
    const exitCode = await proc.exited;
    const stderr = await new Response(proc.stderr).text();
    const stdout = await new Response(proc.stdout).text();
    expect(exitCode).toBe(1);
    expect(stdout).toBe("");
    expect(stderr).toContain("invalid json");
  });

  test("stdin json missing title exits 1", async () => {
    const proc = Bun.spawn(["bun", cliPath], {
      stdout: "pipe",
      stderr: "pipe",
      stdin: new Blob(['{"body":"no title"}']),
    });
    const exitCode = await proc.exited;
    const stderr = await new Response(proc.stderr).text();
    const stdout = await new Response(proc.stdout).text();
    expect(exitCode).toBe(1);
    expect(stdout).toBe("");
    expect(stderr).toContain("title is required");
  });

  test("args take precedence over stdin", async () => {
    // Args provide title, stdin also has JSON — args should win
    // Since daemon isn't running, we expect exit 2 (daemon not running)
    // not exit 1 (which would indicate stdin parsing was used)
    const proc = Bun.spawn(["bun", cliPath, "FromArgs"], {
      stdout: "pipe",
      stderr: "pipe",
      stdin: new Blob(['{"title":"FromStdin"}']),
      env: {
        ...process.env,
        HOME: "/tmp/codo-test-nonexistent",
      },
    });
    const exitCode = await proc.exited;
    const stderr = await new Response(proc.stderr).text();
    expect(exitCode).toBe(2);
    expect(stderr).toContain("daemon not running");
  });

  test("--template list exits 0", async () => {
    const proc = Bun.spawn(["bun", cliPath, "--template", "list"], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const exitCode = await proc.exited;
    const stderr = await new Response(proc.stderr).text();
    const stdout = await new Response(proc.stdout).text();
    expect(exitCode).toBe(0);
    expect(stdout).toBe("");
    expect(stderr).toContain("success");
    expect(stderr).toContain("error");
    expect(stderr).toContain("deploy");
  });

  test("--template unknown exits 1", async () => {
    const proc = Bun.spawn(["bun", cliPath, "Title", "--template", "nope"], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const exitCode = await proc.exited;
    const stderr = await new Response(proc.stderr).text();
    expect(exitCode).toBe(1);
    expect(stderr).toContain("unknown template: nope");
  });
});
