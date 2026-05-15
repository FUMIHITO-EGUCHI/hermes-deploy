import { execFile } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const __dirname = dirname(fileURLToPath(import.meta.url));

interface BitwardenStatus {
  status: string;
}

interface BitwardenField {
  name: string;
  value?: string;
}

interface BitwardenItem {
  name?: string;
  fields?: BitwardenField[];
  login?: {
    password?: string;
  };
  notes?: string;
}

export function extractDeepSeekApiKey(item: BitwardenItem): string | null {
  const fieldNames = [
    "DEEPSEEK_API_KEY",
    "deepseek_api_key",
    "DeepSeek API Key",
    "api_key",
    "API Key",
    "key",
  ];

  for (const name of fieldNames) {
    const field = item.fields?.find((entry) => entry.name === name);
    if (field?.value) {
      return field.value.trim();
    }
  }

  if (item.login?.password?.startsWith("sk-")) {
    return item.login.password.trim();
  }

  const noteMatch = item.notes?.match(/sk-[A-Za-z0-9_\-]+/);
  if (noteMatch) {
    return noteMatch[0];
  }

  return null;
}

export function redactSecret(value: string): string {
  if (value.length <= 10) {
    return "[redacted]";
  }
  return `${value.slice(0, 4)}...${value.slice(-4)}`;
}

export async function getDeepSeekApiKeyFromBitwarden(itemQuery: string): Promise<string> {
  const status = JSON.parse(await runBw(["status"])) as BitwardenStatus;
  if (status.status !== "unlocked") {
    throw new Error(
      `Bitwarden CLI is ${status.status}. Run "npx bw login" if needed, then set BW_SESSION from "npx bw unlock --raw".`,
    );
  }

  const item = JSON.parse(await runBw(["get", "item", itemQuery])) as BitwardenItem;
  const apiKey = extractDeepSeekApiKey(item);
  if (!apiKey) {
    throw new Error(
      `Could not find DeepSeek API key in Bitwarden item "${itemQuery}". Use a custom field named DEEPSEEK_API_KEY or api_key, or store it as the login password.`,
    );
  }

  console.error(
    `Loaded DeepSeek API key from Bitwarden item "${item.name ?? itemQuery}" (${redactSecret(apiKey)}).`,
  );
  return apiKey;
}

async function runBw(args: string[]): Promise<string> {
  const bwJs = join(__dirname, "..", "..", "node_modules", "@bitwarden", "cli", "build", "bw.js");
  const { stdout } = await execFileAsync(process.execPath, [bwJs, ...args], {
    maxBuffer: 10 * 1024 * 1024,
    env: process.env,
  });
  return stdout;
}

