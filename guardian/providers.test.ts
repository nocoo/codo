import { describe, expect, test } from "bun:test";
import {
  AI_PROVIDERS,
  ALL_PROVIDER_IDS,
  isValidProvider,
  getProviderConfig,
  resolveProviderConfig,
} from "./providers";

describe("AI_PROVIDERS registry", () => {
  test("has 4 built-in providers", () => {
    expect(Object.keys(AI_PROVIDERS)).toHaveLength(4);
  });

  test("each provider has required fields", () => {
    for (const [id, info] of Object.entries(AI_PROVIDERS)) {
      expect(info.id).toBe(id);
      expect(info.label).toBeTruthy();
      expect(info.baseURL).toMatch(/^https:\/\//);
      expect(["anthropic", "openai"]).toContain(info.sdkType);
      expect(info.models.length).toBeGreaterThan(0);
      expect(info.models).toContain(info.defaultModel);
    }
  });

  test("anthropic provider uses anthropic SDK", () => {
    expect(AI_PROVIDERS.anthropic.sdkType).toBe("anthropic");
    expect(AI_PROVIDERS.anthropic.baseURL).toContain("anthropic.com");
  });

  test("aihubmix provider uses openai SDK", () => {
    expect(AI_PROVIDERS.aihubmix.sdkType).toBe("openai");
  });
});

describe("ALL_PROVIDER_IDS", () => {
  test("includes all built-in + custom", () => {
    expect(ALL_PROVIDER_IDS).toContain("anthropic");
    expect(ALL_PROVIDER_IDS).toContain("minimax");
    expect(ALL_PROVIDER_IDS).toContain("glm");
    expect(ALL_PROVIDER_IDS).toContain("aihubmix");
    expect(ALL_PROVIDER_IDS).toContain("custom");
    expect(ALL_PROVIDER_IDS).toHaveLength(5);
  });
});

describe("isValidProvider", () => {
  test("valid providers return true", () => {
    expect(isValidProvider("anthropic")).toBe(true);
    expect(isValidProvider("minimax")).toBe(true);
    expect(isValidProvider("custom")).toBe(true);
  });

  test("invalid providers return false", () => {
    expect(isValidProvider("unknown")).toBe(false);
    expect(isValidProvider("")).toBe(false);
    expect(isValidProvider("openai")).toBe(false);
  });
});

describe("getProviderConfig", () => {
  test("returns config for built-in providers", () => {
    const config = getProviderConfig("anthropic");
    expect(config).toBeDefined();
    expect(config?.id).toBe("anthropic");
    expect(config?.sdkType).toBe("anthropic");
  });

  test("returns undefined for custom", () => {
    expect(getProviderConfig("custom")).toBeUndefined();
  });
});

describe("resolveProviderConfig", () => {
  test("built-in provider fills baseURL and sdkType from registry", () => {
    const resolved = resolveProviderConfig({
      provider: "anthropic",
      apiKey: "sk-test",
      model: "claude-sonnet-4-20250514",
    });
    expect(resolved.baseURL).toBe("https://api.anthropic.com/v1");
    expect(resolved.sdkType).toBe("anthropic");
    expect(resolved.model).toBe("claude-sonnet-4-20250514");
  });

  test("built-in provider uses default model when empty", () => {
    const resolved = resolveProviderConfig({
      provider: "anthropic",
      apiKey: "sk-test",
      model: "",
    });
    expect(resolved.model).toBe("claude-sonnet-4-20250514");
  });

  test("custom provider requires baseURL", () => {
    expect(() =>
      resolveProviderConfig({
        provider: "custom",
        apiKey: "sk-test",
        model: "my-model",
        sdkType: "openai",
      }),
    ).toThrow("Base URL is required");
  });

  test("custom provider requires sdkType", () => {
    expect(() =>
      resolveProviderConfig({
        provider: "custom",
        apiKey: "sk-test",
        model: "my-model",
        baseURL: "https://example.com/v1",
      }),
    ).toThrow("SDK type is required");
  });

  test("custom provider requires model", () => {
    expect(() =>
      resolveProviderConfig({
        provider: "custom",
        apiKey: "sk-test",
        model: "",
        baseURL: "https://example.com/v1",
        sdkType: "openai",
      }),
    ).toThrow("Model is required");
  });

  test("custom provider resolves correctly", () => {
    const resolved = resolveProviderConfig({
      provider: "custom",
      apiKey: "sk-test",
      model: "my-model",
      baseURL: "https://example.com/v1",
      sdkType: "openai",
    });
    expect(resolved.provider).toBe("custom");
    expect(resolved.baseURL).toBe("https://example.com/v1");
    expect(resolved.sdkType).toBe("openai");
    expect(resolved.model).toBe("my-model");
  });

  test("missing apiKey throws", () => {
    expect(() =>
      resolveProviderConfig({
        provider: "anthropic",
        apiKey: "",
        model: "",
      }),
    ).toThrow("API key is required");
  });
});
