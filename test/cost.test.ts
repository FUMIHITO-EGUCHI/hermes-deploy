import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { estimateDeepSeekCost } from "../src/core/cost.js";

describe("estimateDeepSeekCost", () => {
  it("uses DeepSeek prompt cache hit and miss token fields when present", () => {
    const cost = estimateDeepSeekCost({
      prompt_tokens: 1689,
      completion_tokens: 42,
      prompt_cache_hit_tokens: 1664,
      prompt_cache_miss_tokens: 25,
      completion_tokens_details: {
        reasoning_tokens: 0,
      },
    });

    assert.equal(cost.cacheHitTokens, 1664);
    assert.equal(cost.cacheMissTokens, 25);
    assert.equal(cost.outputTokens, 42);
    assert.equal(cost.reasoningTokens, 0);
    assert.equal(cost.cacheHitRate, 1664 / 1689);
  });

  it("falls back to prompt_tokens_details.cached_tokens and derives misses", () => {
    const cost = estimateDeepSeekCost({
      prompt_tokens: 647,
      completion_tokens: 12,
      prompt_tokens_details: {
        cached_tokens: 640,
      },
    });

    assert.equal(cost.cacheHitTokens, 640);
    assert.equal(cost.cacheMissTokens, 7);
    assert.equal(cost.outputTokens, 12);
  });

  it("does not produce negative miss tokens when cached tokens exceed prompt tokens", () => {
    const cost = estimateDeepSeekCost({
      prompt_tokens: 10,
      prompt_tokens_details: {
        cached_tokens: 12,
      },
    });

    assert.equal(cost.cacheMissTokens, 0);
  });
});

