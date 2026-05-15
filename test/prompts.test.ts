import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { buildHermesMessages } from "../src/core/prompts/index.js";

describe("buildHermesMessages", () => {
  it("keeps fixed instructions in the system message and dynamic context in the user message", () => {
    const messages = buildHermesMessages(
      {
        gateway: "cli",
        taskId: "task-1",
        currentDate: "2026-05-15",
        timezone: "Asia/Tokyo",
      },
      "Hello",
    );

    assert.equal(messages.length, 2);
    assert.equal(messages[0]?.role, "system");
    assert.equal(messages[1]?.role, "user");
    assert.match(String(messages[0]?.content), /Hermes tool policy/);
    assert.doesNotMatch(String(messages[0]?.content), /task-1/);
    assert.match(String(messages[1]?.content), /Task id: task-1/);
    assert.match(String(messages[1]?.content), /User request:\nHello/);
  });
});

