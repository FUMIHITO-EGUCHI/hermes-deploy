import type { ChatCompletionMessageParam } from "openai/resources/chat/completions";
import { HERMES_SYSTEM_PROMPT } from "./system.js";
import { HERMES_TOOL_POLICY } from "./tool-policy.js";

export interface RuntimeContext {
  gateway: string;
  taskId: string;
  currentDate: string;
  timezone: string;
}

export function buildHermesMessages(
  runtimeContext: RuntimeContext,
  userMessage: string,
): ChatCompletionMessageParam[] {
  return [
    {
      role: "system",
      content: `${HERMES_SYSTEM_PROMPT}\n\n${HERMES_TOOL_POLICY}`,
    },
    {
      role: "user",
      content: `
Runtime context:
- Gateway: ${runtimeContext.gateway}
- Current date: ${runtimeContext.currentDate}
- Timezone: ${runtimeContext.timezone}
- Task id: ${runtimeContext.taskId}

User request:
${userMessage}
`.trim(),
    },
  ];
}

