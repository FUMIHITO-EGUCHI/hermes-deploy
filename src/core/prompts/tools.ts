import type { ChatCompletionTool } from "openai/resources/chat/completions";

export const HERMES_TOOLS: ChatCompletionTool[] = [
  {
    type: "function",
    function: {
      name: "web_search",
      description:
        "Search the public web for current or externally verifiable information. Use for news, prices, documentation, availability, model/provider status, laws, schedules, and other facts that may have changed.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          query: { type: "string", description: "Precise search query." },
          freshness: {
            type: "string",
            enum: ["any", "day", "week", "month", "year"],
            description: "Freshness preference for results.",
          },
          domains: {
            type: "array",
            items: { type: "string" },
            description: "Optional allowed domains.",
          },
        },
        required: ["query", "freshness"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "open_url",
      description:
        "Open and read a specific URL. Use after web_search or when the user provides a URL. Extract only task-relevant facts and cite the URL in the response.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          url: { type: "string" },
          purpose: { type: "string" },
        },
        required: ["url", "purpose"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "memory_search",
      description:
        "Search Hermes long-term memory for prior user preferences, previous task outcomes, repeated workflows, saved decisions, project facts, or known constraints.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          query: { type: "string" },
          limit: { type: "integer", minimum: 1, maximum: 20 },
        },
        required: ["query", "limit"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "file_search",
      description:
        "Search indexed user files or project documents. Use for user-provided materials, internal docs, specifications, meeting notes, spreadsheets, PDFs, and repository documentation.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          query: { type: "string" },
          scope: {
            type: "string",
            enum: ["all", "project", "user_docs", "uploads"],
          },
          limit: { type: "integer", minimum: 1, maximum: 50 },
        },
        required: ["query", "scope", "limit"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "cost_report",
      description:
        "Estimate or report model/API cost for a completed or planned task. Use token usage, cached token usage, provider pricing, tool call counts, and gateway overhead when available.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          provider: { type: "string" },
          model: { type: "string" },
          prompt_tokens: { type: "integer", minimum: 0 },
          cache_hit_tokens: { type: "integer", minimum: 0 },
          cache_miss_tokens: { type: "integer", minimum: 0 },
          completion_tokens: { type: "integer", minimum: 0 },
          notes: { type: "string" },
        },
        required: [
          "provider",
          "model",
          "prompt_tokens",
          "cache_hit_tokens",
          "cache_miss_tokens",
          "completion_tokens",
          "notes",
        ],
      },
    },
  },
];

