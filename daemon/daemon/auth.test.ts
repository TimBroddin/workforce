import { test, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, unlinkSync, mkdirSync } from "node:fs";
import { generateToken, loadOrCreateToken, validateToken } from "./auth";

const TEST_DIR = "/tmp/workforce-test-auth";
const TEST_TOKEN_PATH = `${TEST_DIR}/daemon.token`;

beforeEach(() => {
  mkdirSync(TEST_DIR, { recursive: true });
});

afterEach(() => {
  if (existsSync(TEST_TOKEN_PATH)) unlinkSync(TEST_TOKEN_PATH);
});

test("generateToken returns a UUID-like string", () => {
  const token = generateToken();
  expect(token).toMatch(/^[a-f0-9-]{36}$/);
});

test("loadOrCreateToken creates token file if missing", async () => {
  const token = await loadOrCreateToken(TEST_TOKEN_PATH);
  expect(token).toMatch(/^[a-f0-9-]{36}$/);
  expect(existsSync(TEST_TOKEN_PATH)).toBe(true);
});

test("loadOrCreateToken returns existing token", async () => {
  const token1 = await loadOrCreateToken(TEST_TOKEN_PATH);
  const token2 = await loadOrCreateToken(TEST_TOKEN_PATH);
  expect(token1).toBe(token2);
});

test("validateToken accepts valid token", async () => {
  const token = await loadOrCreateToken(TEST_TOKEN_PATH);
  expect(validateToken(`Bearer ${token}`, token)).toBe(true);
});

test("validateToken rejects invalid token", async () => {
  expect(validateToken("Bearer wrong", "correct")).toBe(false);
});

test("validateToken accepts query param token", async () => {
  const token = "test-token-123";
  expect(validateToken(null, token, token)).toBe(true);
});
