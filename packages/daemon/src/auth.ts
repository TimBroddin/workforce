import { existsSync, chmodSync } from "node:fs";
import { timingSafeEqual } from "node:crypto";

function safeEqual(a: string, b: string): boolean {
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  if (bufA.length !== bufB.length) return false;
  return timingSafeEqual(bufA, bufB);
}

export function generateToken(): string {
  return crypto.randomUUID();
}

export async function loadOrCreateToken(tokenPath: string): Promise<string> {
  if (existsSync(tokenPath)) {
    const file = Bun.file(tokenPath);
    const existing = (await file.text()).trim();
    if (existing) return existing;
    console.warn(`Token file ${tokenPath} was empty, regenerating`);
  }
  const token = generateToken();
  await Bun.write(tokenPath, token);
  chmodSync(tokenPath, 0o600);
  return token;
}

/**
 * Validate an API token from either the Authorization header or a query parameter.
 * Uses constant-time comparison to prevent timing attacks.
 *
 * @param queryToken - Should only be used for WebSocket upgrade handshakes,
 *   where setting custom headers is not possible from the browser.
 */
export function validateToken(
  authHeader: string | null,
  expectedToken: string,
  queryToken?: string
): boolean {
  if (queryToken && safeEqual(queryToken, expectedToken)) return true;
  if (!authHeader) return false;
  if (!authHeader.startsWith("Bearer ")) return false;
  const token = authHeader.slice(7);
  return safeEqual(token, expectedToken);
}
