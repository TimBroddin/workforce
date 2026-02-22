# Notification Summaries Design

**Date:** 2026-02-22
**Status:** Approved

## Problem

When an agent asks for input, the macOS notification only shows "Waiting for your input" — no context about what the agent has been doing or what it needs.

## Solution

Replace the generic notification body with an LLM-generated summary of the agent's recent transcript activity. Support two summarization backends: Apple Intelligence (on-device, default) and OpenRouter/Gemini Flash (API-based, configurable).

## Data Flow

```
Claude Hook (stdin JSON with transcript_path, message)
  → NotificationCommand (decodes transcript_path)
  → SocketMessage (includes transcriptPath)
  → AgentStore (stores transcriptPath on Agent)
  → NotificationManager.notifyIfNeeded()
    → reads last ~10 assistant messages from transcript JSONL
    → TranscriptSummarizer.summarize(messages)
    → UNNotification with summary as body
```

## Changes Required

### 1. Expand NotificationEvent model

Add `transcriptPath` and `message` fields to `NotificationEvent` in `WorkforceKit/Sources/WorkforceKit/Models/HookEvent.swift`. The Claude hook already sends these — we just aren't decoding them.

### 2. Add transcriptPath to SocketMessage

Add optional `transcriptPath: String?` field to `SocketMessage` so the CLI can forward the transcript location to the macOS app.

### 3. Store transcriptPath on Agent model

Add `transcriptPath: String?` to the `Agent` struct in `Workforce/Workforce/Models/Agent.swift`.

### 4. Forward transcriptPath in NotificationCommand

Update `NotificationCommand` to pass `transcriptPath` through the `SocketMessage`.

### 5. Store transcriptPath in AgentStore

Update the `.notification` case in `AgentStore.handleMessage()` to persist `transcriptPath` on the agent.

### 6. Create TranscriptSummarizer service

New file: `Workforce/Workforce/Services/TranscriptSummarizer.swift`

Responsibilities:
- Read last ~10 messages from a JSONL transcript file
- Extract assistant text content blocks
- Summarize via one of two backends:
  - **Apple Intelligence**: Use Foundation Models framework (`FoundationModels.LanguageModelSession`)
  - **OpenRouter**: HTTP POST to `https://openrouter.ai/api/v1/chat/completions` with Gemini Flash
- 3-second timeout — fall back to raw `message` field or generic text on failure
- Prompt: "Summarize what this AI coding agent has been working on in 1-2 short sentences for a macOS notification. Be specific about files and actions."

### 7. Update NotificationManager

Make `notifyIfNeeded` async. When an agent transitions to waiting state:
1. Read transcript from `agent.transcriptPath`
2. Call `TranscriptSummarizer.summarize()`
3. Use the result as the notification body
4. Fall back gracefully on any error

### 8. Settings UI

Add to preferences:
- Summarization backend picker: Apple Intelligence / OpenRouter
- OpenRouter API key field (shown only when OpenRouter selected)
- OpenRouter model field (default: `google/gemini-2.0-flash-001`)

Store in `UserDefaults` via `@AppStorage`.

## Fallback Chain

1. LLM summary of transcript → preferred
2. Raw `message` from hook event (e.g. "Claude needs permission to use Bash") → if summarization fails
3. Generic "Waiting for your input" → if no message available

## Scope

- Notification content only — no UI changes to the main app window
- No new dependencies — Foundation Models is system framework, OpenRouter is plain URLSession
