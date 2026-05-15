import type {
  ChatCompletionMessageParam,
  ChatCompletionTool,
  ChatCompletionToolChoiceOption,
} from "openai/resources/chat/completions";
import type { CostEstimate, DeepSeekTokenUsage } from "../cost.js";

export interface LlmRequest {
  messages: ChatCompletionMessageParam[];
  tools?: ChatCompletionTool[];
  toolChoice?: ChatCompletionToolChoiceOption;
}

export interface LlmUsage {
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
  cacheHitTokens: number;
  cacheMissTokens: number;
  reasoningTokens: number;
  cacheHitRate: number;
  raw: DeepSeekTokenUsage;
}

export interface LlmResponse {
  provider: string;
  model: string;
  content: string;
  usage: LlmUsage;
  cost: CostEstimate;
  rawId?: string;
}

export interface LlmProvider {
  readonly name: string;
  readonly model: string;
  complete(request: LlmRequest): Promise<LlmResponse>;
}

