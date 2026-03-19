/**
 * AI provider registry for Guardian.
 *
 * Mirrors gecko's services/ai.ts provider system.
 * Supports both OpenAI and Anthropic SDK protocols.
 * Built-in providers have hardcoded base URLs and default models.
 * "custom" provider allows user-supplied base URL and SDK type.
 */

export type SdkType = "anthropic" | "openai";

export type AiProvider =
  | "anthropic"
  | "minimax"
  | "glm"
  | "aihubmix"
  | "custom";

export interface AiProviderInfo {
  id: AiProvider;
  label: string;
  baseURL: string;
  sdkType: SdkType;
  models: string[];
  defaultModel: string;
}

export const AI_PROVIDERS: Record<
  Exclude<AiProvider, "custom">,
  AiProviderInfo
> = {
  anthropic: {
    id: "anthropic",
    label: "Anthropic",
    baseURL: "https://api.anthropic.com",
    sdkType: "anthropic",
    models: ["claude-sonnet-4-20250514"],
    defaultModel: "claude-sonnet-4-20250514",
  },
  minimax: {
    id: "minimax",
    label: "MiniMax",
    baseURL: "https://api.minimaxi.com/anthropic",
    sdkType: "anthropic",
    models: ["MiniMax-M2.7", "MiniMax-M2.5", "MiniMax-M2.1"],
    defaultModel: "MiniMax-M2.7",
  },
  glm: {
    id: "glm",
    label: "GLM (Zhipu)",
    baseURL: "https://open.bigmodel.cn/api/anthropic",
    sdkType: "anthropic",
    models: ["glm-5", "glm-4.7"],
    defaultModel: "glm-5",
  },
  aihubmix: {
    id: "aihubmix",
    label: "AIHubMix",
    baseURL: "https://aihubmix.com/v1",
    sdkType: "openai",
    models: ["gpt-4o-mini", "gpt-5-nano"],
    defaultModel: "gpt-4o-mini",
  },
};

export const ALL_PROVIDER_IDS: AiProvider[] = [
  ...(Object.keys(AI_PROVIDERS) as Exclude<AiProvider, "custom">[]),
  "custom",
];

export function isValidProvider(id: string): id is AiProvider {
  return ALL_PROVIDER_IDS.includes(id as AiProvider);
}

export function getProviderConfig(
  providerId: AiProvider,
): AiProviderInfo | undefined {
  if (providerId === "custom") return undefined;
  return AI_PROVIDERS[providerId];
}

/**
 * Resolve provider + user settings into a complete config.
 * For built-in providers: fills baseURL and sdkType from registry.
 * For custom: requires baseURL and sdkType from environment.
 */
export function resolveProviderConfig(input: {
  provider: AiProvider;
  apiKey: string;
  model: string;
  baseURL?: string;
  sdkType?: SdkType;
}): {
  provider: AiProvider;
  baseURL: string;
  apiKey: string;
  model: string;
  sdkType: SdkType;
} {
  if (!input.apiKey) {
    throw new Error("API key is required");
  }

  if (input.provider === "custom") {
    if (!input.baseURL) {
      throw new Error("Base URL is required for custom provider");
    }
    if (!input.sdkType) {
      throw new Error("SDK type is required for custom provider");
    }
    if (!input.model) {
      throw new Error("Model is required for custom provider");
    }
    return {
      provider: "custom",
      baseURL: input.baseURL,
      apiKey: input.apiKey,
      model: input.model,
      sdkType: input.sdkType,
    };
  }

  const info = getProviderConfig(input.provider);
  if (!info) {
    throw new Error(`Unknown AI provider: ${input.provider}`);
  }

  return {
    provider: input.provider,
    baseURL: info.baseURL,
    apiKey: input.apiKey,
    model: input.model || info.defaultModel,
    sdkType: info.sdkType,
  };
}
