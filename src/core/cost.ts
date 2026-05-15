export interface DeepSeekTokenUsage {
  prompt_tokens?: number;
  completion_tokens?: number;
  total_tokens?: number;
  prompt_tokens_details?: {
    cached_tokens?: number;
  };
  completion_tokens_details?: {
    reasoning_tokens?: number;
  };
  prompt_cache_hit_tokens?: number;
  prompt_cache_miss_tokens?: number;
}

export interface DeepSeekPricing {
  cacheHitInputPer1M: number;
  cacheMissInputPer1M: number;
  outputPer1M: number;
}

export interface CostEstimate {
  cacheHitTokens: number;
  cacheMissTokens: number;
  outputTokens: number;
  reasoningTokens: number;
  cacheHitRate: number;
  inputHitCost: number;
  inputMissCost: number;
  outputCost: number;
  totalCost: number;
}

export const DEEPSEEK_V4_FLASH_PRICING: DeepSeekPricing = {
  cacheHitInputPer1M: 0.0028,
  cacheMissInputPer1M: 0.14,
  outputPer1M: 0.28,
};

export function estimateDeepSeekCost(
  usage: DeepSeekTokenUsage,
  pricing: DeepSeekPricing = DEEPSEEK_V4_FLASH_PRICING,
): CostEstimate {
  const promptTokens = usage.prompt_tokens ?? 0;
  const cacheHitTokens =
    usage.prompt_cache_hit_tokens ?? usage.prompt_tokens_details?.cached_tokens ?? 0;
  const cacheMissTokens =
    usage.prompt_cache_miss_tokens ?? Math.max(promptTokens - cacheHitTokens, 0);
  const outputTokens = usage.completion_tokens ?? 0;
  const reasoningTokens = usage.completion_tokens_details?.reasoning_tokens ?? 0;

  const inputHitCost = (cacheHitTokens / 1_000_000) * pricing.cacheHitInputPer1M;
  const inputMissCost = (cacheMissTokens / 1_000_000) * pricing.cacheMissInputPer1M;
  const outputCost = (outputTokens / 1_000_000) * pricing.outputPer1M;

  return {
    cacheHitTokens,
    cacheMissTokens,
    outputTokens,
    reasoningTokens,
    cacheHitRate: promptTokens > 0 ? cacheHitTokens / promptTokens : 0,
    inputHitCost,
    inputMissCost,
    outputCost,
    totalCost: inputHitCost + inputMissCost + outputCost,
  };
}

export function formatUsd(value: number): string {
  return `$${value.toFixed(10)}`;
}

