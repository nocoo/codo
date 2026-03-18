import { describe, expect, test } from "bun:test";
import { parseArgs, parseStdin } from "./codo.ts";

// MARK: - parseArgs

describe("parseArgs", () => {
  test("title only", () => {
    const result = parseArgs(["Hello"]);
    expect(result).toEqual({
      message: { title: "Hello", body: undefined, sound: "default" },
    });
  });

  test("title and body", () => {
    const result = parseArgs(["Hello", "World"]);
    expect(result).toEqual({
      message: { title: "Hello", body: "World", sound: "default" },
    });
  });

  test("silent flag", () => {
    const result = parseArgs(["Hello", "--silent"]);
    expect(result).toEqual({
      message: { title: "Hello", body: undefined, sound: "none" },
    });
  });

  test("title body and silent", () => {
    const result = parseArgs(["Hello", "World", "--silent"]);
    expect(result).toEqual({
      message: { title: "Hello", body: "World", sound: "none" },
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
    });
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
    });
    const exitCode = await proc.exited;
    const stderr = await new Response(proc.stderr).text();
    const stdout = await new Response(proc.stdout).text();
    expect(exitCode).toBe(2);
    expect(stdout).toBe("");
    expect(stderr).toContain("daemon not running");
  });
});
