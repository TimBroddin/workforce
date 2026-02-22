# Notification Summaries Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace generic "Waiting for your input" notifications with LLM-generated summaries of what the agent has been doing.

**Architecture:** The notification hook event includes a `transcriptPath` field pointing to the session's JSONL transcript. We pipe this path through the socket message to the app, read the last ~10 assistant messages, and summarize them using either Apple Intelligence (Foundation Models) or OpenRouter/Gemini Flash. The summary becomes the notification body.

**Tech Stack:** Swift, Foundation Models framework (macOS 26+ only, conditionally imported), URLSession for OpenRouter API, UserDefaults/@AppStorage for settings.

**Compatibility:** Deployment target is already macOS 14.6 (Sonoma). Apple Intelligence backend is gated behind `#if canImport(FoundationModels)` and `@available(macOS 26, *)`. On macOS < 26, only the OpenRouter backend is available and is the default. No deployment target changes needed.

---

### Task 1: Add transcriptPath to NotificationEvent

**Files:**
- Modify: `WorkforceKit/Sources/WorkforceKit/Models/HookEvent.swift:46-58`

**Step 1: Add fields to NotificationEvent**

In `HookEvent.swift`, add `transcriptPath` and `message` to `NotificationEvent`:

```swift
public struct NotificationEvent: Decodable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let hookEventName: String
    public let type: String?
    public let transcriptPath: String?
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case type
        case transcriptPath = "transcript_path"
        case message
    }
}
```

**Step 2: Verify it compiles**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift build`
Expected: Build succeeds.

**Step 3: Commit**

```bash
git add WorkforceKit/Sources/WorkforceKit/Models/HookEvent.swift
git commit -m "feat: decode transcriptPath and message from notification hook event"
```

---

### Task 2: Add transcriptPath to SocketMessage (both copies)

**Files:**
- Modify: `WorkforceKit/Sources/WorkforceKit/Models/SocketMessage.swift`
- Modify: `Workforce/Workforce/Models/SocketMessage.swift`

**Step 1: Add field to WorkforceKit SocketMessage**

Add `transcriptPath: String?` to the struct and init in `WorkforceKit/Sources/WorkforceKit/Models/SocketMessage.swift`:

Property:
```swift
    // Notification context fields
    public var transcriptPath: String?
```

Init parameter (add after `cacheReadTokens`):
```swift
        transcriptPath: String? = nil
```

Init body (add after `self.cacheReadTokens`):
```swift
        self.transcriptPath = transcriptPath
```

**Step 2: Add field to App SocketMessage**

Same change in `Workforce/Workforce/Models/SocketMessage.swift`:

Property:
```swift
    // Notification context fields
    public var transcriptPath: String?
```

Init parameter (add after `cacheReadTokens`):
```swift
        transcriptPath: String? = nil
```

Init body (add after `self.cacheReadTokens`):
```swift
        self.transcriptPath = transcriptPath
```

**Step 3: Verify both compile**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift build`
Run: `cd /Users/timbroddin/Projects/workforce && xcodebuild -project Workforce/Workforce.xcodeproj -scheme Workforce -quiet build 2>&1 | tail -5`

**Step 4: Commit**

```bash
git add WorkforceKit/Sources/WorkforceKit/Models/SocketMessage.swift Workforce/Workforce/Models/SocketMessage.swift
git commit -m "feat: add transcriptPath field to SocketMessage"
```

---

### Task 3: Add transcriptPath to Agent model (both copies)

**Files:**
- Modify: `WorkforceKit/Sources/WorkforceKit/Models/Agent.swift`
- Modify: `Workforce/Workforce/Models/Agent.swift`

**Step 1: Add field to both Agent structs**

Add `public var transcriptPath: String?` property after `paneTitle`:
```swift
    public var paneTitle: String?
    public var transcriptPath: String?
```

Add init parameter (after `paneTitle`):
```swift
        paneTitle: String? = nil,
        transcriptPath: String? = nil,
```

Add init body (after `self.paneTitle`):
```swift
        self.transcriptPath = transcriptPath
```

Apply this to both:
- `WorkforceKit/Sources/WorkforceKit/Models/Agent.swift`
- `Workforce/Workforce/Models/Agent.swift`

**Step 2: Verify both compile**

**Step 3: Commit**

```bash
git add WorkforceKit/Sources/WorkforceKit/Models/Agent.swift Workforce/Workforce/Models/Agent.swift
git commit -m "feat: add transcriptPath to Agent model"
```

---

### Task 4: Forward transcriptPath in NotificationCommand

**Files:**
- Modify: `WorkforceKit/Sources/WorkforceCLI/Commands/NotificationCommand.swift`

**Step 1: Pass transcriptPath through SocketMessage**

```swift
struct NotificationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notification",
        abstract: "Handle Notification hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(NotificationEvent.self, from: data)
        let status: AgentStatus = event.type == "permission_prompt"
            ? .waitingForPermission
            : .waitingForInput
        SocketClient.send(SocketMessage(
            type: .notification,
            sessionId: resolveSessionId(from: event.sessionId),
            cwd: event.cwd,
            status: status,
            notificationType: event.type,
            transcriptPath: event.transcriptPath
        ))
    }
}
```

**Step 2: Verify it compiles**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift build`

**Step 3: Commit**

```bash
git add WorkforceKit/Sources/WorkforceCLI/Commands/NotificationCommand.swift
git commit -m "feat: forward transcriptPath from hook event to socket message"
```

---

### Task 5: Store transcriptPath in AgentStore

**Files:**
- Modify: `Workforce/Workforce/Services/AgentStore.swift:49-56`

**Step 1: Update notification handler**

In `AgentStore.handleMessage()`, in the `.notification` case, add:

```swift
        case .notification:
            var agent = ensureAgent(for: message)
            let previousStatus = agent.status
            agent.lastActivityAt = message.timestamp
            agent.lastNotificationType = message.notificationType
            if let path = message.transcriptPath { agent.transcriptPath = path }
            if let status = message.status { agent.status = status }
            agents[message.sessionId] = agent
            NotificationManager.shared.notifyIfNeeded(agent: agent, previousStatus: previousStatus)
```

**Step 2: Verify it compiles**

**Step 3: Commit**

```bash
git add Workforce/Workforce/Services/AgentStore.swift
git commit -m "feat: persist transcriptPath on agent from notification messages"
```

---

### Task 6: Create TranscriptReader utility

**Files:**
- Create: `Workforce/Workforce/Services/TranscriptReader.swift`

**Step 1: Create TranscriptReader**

This reads the last N assistant messages from a JSONL transcript file.

```swift
import Foundation

enum TranscriptReader {
    /// Reads the last `count` assistant text messages from a JSONL transcript file.
    static func lastAssistantMessages(from path: String, count: Int = 10) -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var messages: [String] = []
        for line in content.split(separator: "\n").reversed() where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let role = message["role"] as? String,
                  role == "assistant",
                  let contentBlocks = message["content"] as? [[String: Any]] else {
                continue
            }

            let texts = contentBlocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }

            if !texts.isEmpty {
                messages.append(texts.joined(separator: "\n"))
            }

            if messages.count >= count { break }
        }

        return messages.reversed()
    }
}
```

**Step 2: Verify it compiles**

**Step 3: Commit**

```bash
git add Workforce/Workforce/Services/TranscriptReader.swift
git commit -m "feat: add TranscriptReader to extract assistant messages from JSONL"
```

---

### Task 7: Create TranscriptSummarizer with conditional Apple Intelligence backend

**Files:**
- Create: `Workforce/Workforce/Services/TranscriptSummarizer.swift`

**Step 1: Create the summarizer**

Uses `#if canImport(FoundationModels)` for compile-time gating and `@available(macOS 26, *)` for runtime checks. On macOS < 26, only OpenRouter is available.

```swift
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum SummarizationBackend: String, CaseIterable, Identifiable {
    case appleIntelligence = "Apple Intelligence"
    case openRouter = "OpenRouter"
    var id: String { rawValue }

    /// Backends available on the current system.
    static var availableCases: [SummarizationBackend] {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return allCases
        }
        #endif
        return [.openRouter]
    }

    /// Sensible default for the current system.
    static var systemDefault: SummarizationBackend {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return .appleIntelligence
        }
        #endif
        return .openRouter
    }
}

actor TranscriptSummarizer {
    static let shared = TranscriptSummarizer()

    private let systemPrompt = """
    Summarize what this AI coding agent has been working on in 1-2 short sentences \
    for a macOS notification. Be specific about files and actions. \
    Do not start with "The agent" — just describe the work.
    """

    func summarize(transcriptPath: String) async -> String? {
        let messages = TranscriptReader.lastAssistantMessages(from: transcriptPath, count: 10)
        guard !messages.isEmpty else { return nil }

        // Truncate to ~4000 chars to keep it fast
        let combined = messages.joined(separator: "\n---\n")
        let truncated = String(combined.prefix(4000))

        let backend = SummarizationBackend(
            rawValue: UserDefaults.standard.string(forKey: "summarizationBackend") ?? SummarizationBackend.systemDefault.rawValue
        ) ?? .systemDefault

        do {
            return try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    switch backend {
                    case .appleIntelligence:
                        return try await self.summarizeWithAppleIntelligence(truncated)
                    case .openRouter:
                        return try await self.summarizeWithOpenRouter(truncated)
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(3))
                    return nil // timeout sentinel
                }
                // First result wins
                for try await result in group {
                    group.cancelAll()
                    return result
                }
                return nil
            }
        } catch {
            return nil
        }
    }

    private func summarizeWithAppleIntelligence(_ text: String) async throws -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return nil }
        let model = SystemLanguageModel.default
        guard model.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: systemPrompt)
        let response = try await session.respond(to: text)
        let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
        #else
        return nil
        #endif
    }

    private func summarizeWithOpenRouter(_ text: String) async throws -> String? {
        guard let apiKey = UserDefaults.standard.string(forKey: "openRouterAPIKey"),
              !apiKey.isEmpty else { return nil }
        let model = UserDefaults.standard.string(forKey: "openRouterModel") ?? "google/gemini-2.0-flash-001"

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
            "max_tokens": 100,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
```

**Step 2: Verify it compiles**

**Step 3: Commit**

```bash
git add Workforce/Workforce/Services/TranscriptSummarizer.swift
git commit -m "feat: add TranscriptSummarizer with Apple Intelligence and OpenRouter backends"
```

---

### Task 8: Update NotificationManager to use summaries

**Files:**
- Modify: `Workforce/Workforce/Services/NotificationManager.swift`

**Step 1: Make notifyIfNeeded async and use summarizer**

Replace the current `notifyIfNeeded` method:

```swift
    func notifyIfNeeded(agent: Agent, previousStatus: AgentStatus?) {
        guard agent.status == .waitingForInput || agent.status == .waitingForPermission else { return }
        guard previousStatus != agent.status else { return }

        let defaultBody = agent.status == .waitingForPermission
            ? "Needs permission to continue"
            : "Waiting for your input"

        // Fire notification immediately with default text, then update if summary arrives
        let identifier = "workforce-\(agent.sessionId)"
        sendNotification(identifier: identifier, title: agent.displayTitle, body: defaultBody, sessionId: agent.sessionId)

        // Try to enrich with transcript summary
        if let transcriptPath = agent.transcriptPath {
            Task {
                if let summary = await TranscriptSummarizer.shared.summarize(transcriptPath: transcriptPath) {
                    await MainActor.run {
                        self.sendNotification(identifier: identifier, title: agent.displayTitle, body: summary, sessionId: agent.sessionId)
                    }
                }
            }
        }
    }

    private func sendNotification(identifier: String, title: String, body: String, sessionId: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionId": sessionId]

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
```

This sends the notification immediately with the generic text, then replaces it with the summary once ready (same identifier = replacement).

**Step 2: Verify it compiles**

**Step 3: Commit**

```bash
git add Workforce/Workforce/Services/NotificationManager.swift
git commit -m "feat: enrich notifications with transcript summaries"
```

---

### Task 9: Add summarization settings to SettingsView

**Files:**
- Modify: `Workforce/Workforce/Views/SettingsView.swift`

**Step 1: Add settings section**

Add these `@AppStorage` properties at the top of `SettingsView`:

```swift
    @AppStorage("summarizationBackend") private var summarizationBackend: String = SummarizationBackend.systemDefault.rawValue
    @AppStorage("openRouterAPIKey") private var openRouterAPIKey: String = ""
    @AppStorage("openRouterModel") private var openRouterModel: String = "google/gemini-2.0-flash-001"
```

Add this section in the `Form`, before the "Workforce CLI & Hooks" section:

```swift
            Section("Notification Summaries") {
                Picker("Backend", selection: $summarizationBackend) {
                    ForEach(SummarizationBackend.availableCases) { backend in
                        Text(backend.rawValue).tag(backend.rawValue)
                    }
                }

                if summarizationBackend == SummarizationBackend.openRouter.rawValue {
                    SecureField("OpenRouter API Key", text: $openRouterAPIKey)
                    TextField("Model", text: $openRouterModel)
                        .font(.caption)
                }
            }
```

Note: Uses `availableCases` instead of `allCases` — on macOS < 26, only "OpenRouter" is shown in the picker.

**Step 2: Verify it compiles**

**Step 3: Commit**

```bash
git add Workforce/Workforce/Views/SettingsView.swift
git commit -m "feat: add notification summary backend settings"
```

---

### Task 10: Add TranscriptReader and TranscriptSummarizer to Xcode project

**Files:**
- Modify: `Workforce/Workforce.xcodeproj/project.pbxproj` (via Xcode or manual file reference)

**Step 1: Add new files to Xcode project**

The new files need to be added to the Xcode project's build sources:
- `Workforce/Workforce/Services/TranscriptReader.swift`
- `Workforce/Workforce/Services/TranscriptSummarizer.swift`

Since the project uses a folder reference or file list, check if files in `Services/` are automatically included. If not, add them to the project.pbxproj.

**Step 2: Full build test**

Run: `cd /Users/timbroddin/Projects/workforce && xcodebuild -project Workforce/Workforce.xcodeproj -scheme Workforce -quiet build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

**Step 3: Manual test**

1. Launch the app
2. Check Settings → verify "Notification Summaries" section appears
3. Start a Claude agent, let it work, then trigger a notification
4. Verify the notification body shows a summary instead of generic text

**Step 4: Commit**

```bash
git add Workforce/Workforce.xcodeproj/project.pbxproj
git commit -m "feat: add new files to Xcode project"
```
