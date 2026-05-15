import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { extractDeepSeekApiKey, redactSecret } from "../src/secrets/bitwarden.js";

describe("extractDeepSeekApiKey", () => {
  it("prefers the DEEPSEEK_API_KEY custom field", () => {
    const key = extractDeepSeekApiKey({
      fields: [
        { name: "api_key", value: "sk-secondary" },
        { name: "DEEPSEEK_API_KEY", value: " sk-primary " },
      ],
    });

    assert.equal(key, "sk-primary");
  });

  it("falls back to a login password that looks like an API key", () => {
    const key = extractDeepSeekApiKey({
      login: {
        password: "sk-password",
      },
    });

    assert.equal(key, "sk-password");
  });
});

describe("redactSecret", () => {
  it("keeps only a short prefix and suffix for logs", () => {
    assert.equal(redactSecret("sk-abcdefghijklmnopqrstuvwxyz"), "sk-a...wxyz");
  });
});

