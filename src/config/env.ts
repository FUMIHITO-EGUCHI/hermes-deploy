import "dotenv/config";
import { z } from "zod";

const envSchema = z.object({
  DEEPSEEK_API_KEY: z.string().min(1).optional(),
  DEEPSEEK_BASE_URL: z.string().url().default("https://api.deepseek.com"),
  DEEPSEEK_MODEL: z.string().min(1).default("deepseek-v4-flash"),
  DEEPSEEK_BW_ITEM: z.string().min(1).default("DeepSeek"),
});

export type HermesEnv = z.infer<typeof envSchema>;

export function loadHermesEnv(env: NodeJS.ProcessEnv = process.env): HermesEnv {
  return envSchema.parse(env);
}
