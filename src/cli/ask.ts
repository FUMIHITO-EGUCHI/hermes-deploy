import { loadHermesEnv } from "../config/env.js";
import { formatUsd } from "../core/cost.js";
import { buildHermesMessages, HERMES_TOOLS } from "../core/prompts/index.js";
import { DeepSeekProvider } from "../core/providers/deepseek.js";
import { getDeepSeekApiKeyFromBitwarden } from "../secrets/bitwarden.js";

function getUserMessage(argv: string[]): string {
  const message = argv.join(" ").trim();
  if (!message) {
    throw new Error('Usage: npm run ask -- "依頼内容"');
  }
  return message;
}

function currentDateInTokyo(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Tokyo",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
}

async function main(): Promise<void> {
  const env = loadHermesEnv();
  const apiKey = env.DEEPSEEK_API_KEY ?? (await getDeepSeekApiKeyFromBitwarden(env.DEEPSEEK_BW_ITEM));
  const userMessage = getUserMessage(process.argv.slice(2));
  const provider = new DeepSeekProvider({
    apiKey,
    baseURL: env.DEEPSEEK_BASE_URL,
    model: env.DEEPSEEK_MODEL,
  });

  const response = await provider.complete({
    messages: buildHermesMessages(
      {
        gateway: "cli",
        currentDate: currentDateInTokyo(),
        timezone: "Asia/Tokyo",
        taskId: `cli-${Date.now()}`,
      },
      userMessage,
    ),
    tools: HERMES_TOOLS,
    toolChoice: "none",
  });

  console.log(response.content);
  console.log(
    JSON.stringify(
      {
        provider: response.provider,
        model: response.model,
        usage: {
          promptTokens: response.usage.promptTokens,
          completionTokens: response.usage.completionTokens,
          totalTokens: response.usage.totalTokens,
          cacheHitTokens: response.usage.cacheHitTokens,
          cacheMissTokens: response.usage.cacheMissTokens,
          reasoningTokens: response.usage.reasoningTokens,
          cacheHitRate: `${(response.usage.cacheHitRate * 100).toFixed(2)}%`,
        },
        estimatedUsd: formatUsd(response.cost.totalCost),
      },
      null,
      2,
    ),
  );
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
