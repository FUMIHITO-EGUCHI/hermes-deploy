import OpenAI from "openai";
import type { ChatCompletion } from "openai/resources/chat/completions";
import { estimateDeepSeekCost, type DeepSeekTokenUsage } from "../cost.js";
import type { LlmProvider, LlmRequest, LlmResponse, LlmUsage } from "./types.js";

export interface DeepSeekProviderOptions {
  apiKey: string;
  baseURL?: string;
  model?: string;
}

export class DeepSeekProvider implements LlmProvider {
  readonly name = "deepseek";
  readonly model: string;

  private readonly client: OpenAI;

  constructor(options: DeepSeekProviderOptions) {
    this.model = options.model ?? "deepseek-v4-flash";
    this.client = new OpenAI({
      apiKey: options.apiKey,
      baseURL: options.baseURL ?? "https://api.deepseek.com",
    });
  }

  async complete(request: LlmRequest): Promise<LlmResponse> {
    const response = await this.client.chat.completions.create({
      model: this.model,
      messages: request.messages,
      tools: request.tools,
      tool_choice: request.toolChoice,
    });

    return mapDeepSeekResponse(this.name, this.model, response);
  }
}

export function mapDeepSeekResponse(
  provider: string,
  model: string,
  response: ChatCompletion,
): LlmResponse {
  const rawUsage = (response.usage ?? {}) as DeepSeekTokenUsage;
  const cost = estimateDeepSeekCost(rawUsage);
  const usage: LlmUsage = {
    promptTokens: rawUsage.prompt_tokens ?? 0,
    completionTokens: rawUsage.completion_tokens ?? 0,
    totalTokens: rawUsage.total_tokens ?? 0,
    cacheHitTokens: cost.cacheHitTokens,
    cacheMissTokens: cost.cacheMissTokens,
    reasoningTokens: cost.reasoningTokens,
    cacheHitRate: cost.cacheHitRate,
    raw: rawUsage,
  };

  return {
    provider,
    model,
    content: extractContent(response),
    usage,
    cost,
    rawId: response.id,
  };
}

function extractContent(response: ChatCompletion): string {
  const content = response.choices[0]?.message.content;
  if (typeof content === "string") {
    return content;
  }
  return "";
}

