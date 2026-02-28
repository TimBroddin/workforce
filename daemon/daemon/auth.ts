import { existsSync, chmodSync } from "node:fs";

export function generateToken(): string {
  return crypto.randomUUID();
}

export async function loadOrCreateToken(tokenPath: string): Promise<string> {
  if (existsSync(tokenPath)) {
    const file = Bun.file(tokenPath);
    const existing = (await file.text()).trim();
    if (existing) return existing;
  }
  const token = generateToken();
  await Bun.write(tokenPath, token);
  chmodSync(tokenPath, 0o600);
  return token;
}

export function validateToken(
  authHeader: string | null,
  expectedToken: string,
  queryToken?: string
): boolean {
  if (queryToken === expectedToken) return true;
  if (!authHeader) return false;
  const token = authHeader.replace("Bearer ", "");
  return token === expectedToken;
}
