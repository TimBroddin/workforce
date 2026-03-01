import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { parseTranscriptTokens } from "../src/transcript";

const TEST_DIR = "/tmp/agenthub-test-transcript";

beforeEach(() => {
  mkdirSync(TEST_DIR, { recursive: true });
});

afterEach(() => {
  rmSync(TEST_DIR, { recursive: true, force: true });
});

test("returns zeros for nonexistent file", async () => {
  const result = await parseTranscriptTokens("/tmp/nonexistent.jsonl");
  expect(result).toEqual({
    inputTokens: 0,
    outputTokens: 0,
    cacheCreationTokens: 0,
    cacheReadTokens: 0,
  });
});

test("parses tokens from JSONL transcript", async () => {
  const filePath = join(TEST_DIR, "transcript.jsonl");
  const lines = [
    JSON.stringify({ type: "human", message: { role: "user", content: "hello" } }),
    JSON.stringify({
      type: "assistant",
      message: {
        role: "assistant",
        content: "hi",
        usage: { input_tokens: 100, output_tokens: 50, cache_creation_input_tokens: 10, cache_read_input_tokens: 20 },
      },
    }),
    JSON.stringify({
      type: "assistant",
      message: {
        role: "assistant",
        content: "bye",
        usage: { input_tokens: 200, output_tokens: 80 },
      },
    }),
  ];
  await Bun.write(filePath, lines.join("\n"));

  const result = await parseTranscriptTokens(filePath);
  expect(result.inputTokens).toBe(300);
  expect(result.outputTokens).toBe(130);
  expect(result.cacheCreationTokens).toBe(10);
  expect(result.cacheReadTokens).toBe(20);
});

test("skips lines without usage", async () => {
  const filePath = join(TEST_DIR, "transcript2.jsonl");
  const lines = [
    JSON.stringify({ type: "human", message: { role: "user", content: "test" } }),
    JSON.stringify({ type: "assistant", message: { role: "assistant", content: "ok" } }),
  ];
  await Bun.write(filePath, lines.join("\n"));

  const result = await parseTranscriptTokens(filePath);
  expect(result.inputTokens).toBe(0);
  expect(result.outputTokens).toBe(0);
});

test("handles empty file", async () => {
  const filePath = join(TEST_DIR, "empty.jsonl");
  await Bun.write(filePath, "");

  const result = await parseTranscriptTokens(filePath);
  expect(result.inputTokens).toBe(0);
});

test("handles malformed JSON lines gracefully", async () => {
  const filePath = join(TEST_DIR, "bad.jsonl");
  const lines = [
    "not json",
    JSON.stringify({
      type: "assistant",
      message: { role: "assistant", content: "ok", usage: { input_tokens: 50, output_tokens: 25 } },
    }),
    "{broken",
  ];
  await Bun.write(filePath, lines.join("\n"));

  const result = await parseTranscriptTokens(filePath);
  expect(result.inputTokens).toBe(50);
  expect(result.outputTokens).toBe(25);
});
