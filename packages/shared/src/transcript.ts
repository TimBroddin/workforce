import { existsSync } from "node:fs";

export interface TokenSummary {
  inputTokens: number;
  outputTokens: number;
  cacheCreationTokens: number;
  cacheReadTokens: number;
}

export async function parseTranscriptTokens(filePath: string): Promise<TokenSummary> {
  const summary: TokenSummary = {
    inputTokens: 0,
    outputTokens: 0,
    cacheCreationTokens: 0,
    cacheReadTokens: 0,
  };

  if (!existsSync(filePath)) return summary;

  const file = Bun.file(filePath);
  const text = await file.text();
  if (!text.trim()) return summary;

  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      const entry = JSON.parse(line);
      const usage = entry?.message?.usage;
      if (!usage) continue;
      summary.inputTokens += usage.input_tokens ?? 0;
      summary.outputTokens += usage.output_tokens ?? 0;
      summary.cacheCreationTokens += usage.cache_creation_input_tokens ?? 0;
      summary.cacheReadTokens += usage.cache_read_input_tokens ?? 0;
    } catch {
      // Skip malformed lines
    }
  }

  return summary;
}
