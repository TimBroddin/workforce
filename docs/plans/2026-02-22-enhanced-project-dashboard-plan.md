# Enhanced Project Dashboard — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add token/cost tracking, a project detail panel (stats/git/activity tabs), and cost badges to the Workforce macOS app.

**Architecture:** The CLI's `StopCommand` parses the Claude Code session transcript JSONL to extract token usage, sends it to the app via the existing Unix socket, and the app accumulates and persists the data. A new `ProjectDetailView` shows project-level stats, git info, and activity when a folder is selected. The existing sidebar gets cost badges.

**Tech Stack:** Swift 6.0, SwiftUI, Foundation, swift-argument-parser, NWListener (Unix socket)

---

## Task 1: Add token fields to shared models (WorkforceKit)

**Files:**
- Modify: `WorkforceKit/Sources/WorkforceKit/Models/SocketMessage.swift`
- Modify: `WorkforceKit/Sources/WorkforceKit/Models/Agent.swift`
- Modify: `WorkforceKit/Tests/WorkforceKitTests/WorkforceKitTests.swift`

**Step 1: Write failing test for SocketMessage token fields**

Add to `WorkforceKit/Tests/WorkforceKitTests/WorkforceKitTests.swift`:

```swift
@Test func socketMessageRoundTripPreservesTokenFields() throws {
    let message = SocketMessage(
        type: .updateTokens,
        sessionId: "session-tok",
        cwd: "/tmp/project",
        inputTokens: 1000,
        outputTokens: 500,
        cacheCreationTokens: 100,
        cacheReadTokens: 200
    )

    let encoded = try JSONEncoder().encode(message)
    let decoded = try JSONDecoder().decode(SocketMessage.self, from: encoded)

    #expect(decoded.type == .updateTokens)
    #expect(decoded.inputTokens == 1000)
    #expect(decoded.outputTokens == 500)
    #expect(decoded.cacheCreationTokens == 100)
    #expect(decoded.cacheReadTokens == 200)
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift test --filter socketMessageRoundTripPreservesTokenFields`
Expected: FAIL — `updateTokens` case doesn't exist, token fields don't exist

**Step 3: Add updateTokens to SocketMessageType and token fields to SocketMessage**

In `WorkforceKit/Sources/WorkforceKit/Models/SocketMessage.swift`:

Add `case updateTokens` to `SocketMessageType` enum.

Add these optional fields to `SocketMessage`:

```swift
public var inputTokens: Int?
public var outputTokens: Int?
public var cacheCreationTokens: Int?
public var cacheReadTokens: Int?
```

Add them to the `init` as optional parameters (defaulting to `nil`).

**Step 4: Add token fields to Agent**

In `WorkforceKit/Sources/WorkforceKit/Models/Agent.swift`:

Add these fields to the `Agent` struct:

```swift
public var totalInputTokens: Int = 0
public var totalOutputTokens: Int = 0
public var totalCacheCreationTokens: Int = 0
public var totalCacheReadTokens: Int = 0
```

Add them to the `init` as optional parameters (defaulting to `0`).

**Step 5: Write failing test for Agent token fields**

Add to `WorkforceKit/Tests/WorkforceKitTests/WorkforceKitTests.swift`:

```swift
@Test func agentTokenFieldsDefaultToZeroAndRoundTrip() throws {
    let agent = Agent(
        sessionId: "session-tok-agent",
        name: "Token Agent",
        avatarSeed: "seed-tok",
        cwd: "/tmp/project",
        totalInputTokens: 5000,
        totalOutputTokens: 2000,
        totalCacheCreationTokens: 300,
        totalCacheReadTokens: 800
    )

    let encoded = try JSONEncoder().encode(agent)
    let decoded = try JSONDecoder().decode(Agent.self, from: encoded)

    #expect(decoded.totalInputTokens == 5000)
    #expect(decoded.totalOutputTokens == 2000)
    #expect(decoded.totalCacheCreationTokens == 300)
    #expect(decoded.totalCacheReadTokens == 800)

    // Default values
    let defaultAgent = Agent(
        sessionId: "default",
        name: "Default",
        avatarSeed: "seed",
        cwd: "/tmp"
    )
    #expect(defaultAgent.totalInputTokens == 0)
    #expect(defaultAgent.totalOutputTokens == 0)
}
```

**Step 6: Run all tests to verify they pass**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift test`
Expected: ALL PASS

**Step 7: Commit**

```bash
git add WorkforceKit/Sources/WorkforceKit/Models/SocketMessage.swift \
        WorkforceKit/Sources/WorkforceKit/Models/Agent.swift \
        WorkforceKit/Tests/WorkforceKitTests/WorkforceKitTests.swift
git commit -m "feat: add token tracking fields to SocketMessage and Agent"
```

---

## Task 2: Add HookEventBase transcript_path field

**Files:**
- Modify: `WorkforceKit/Sources/WorkforceKit/Models/HookEvent.swift`
- Modify: `WorkforceKit/Tests/WorkforceKitTests/WorkforceKitTests.swift`

**Step 1: Write failing test**

Add to `WorkforceKit/Tests/WorkforceKitTests/WorkforceKitTests.swift`:

```swift
@Test func hookEventBaseDecodesTranscriptPath() throws {
    let data = """
    {
      "session_id": "session-tp",
      "cwd": "/tmp/project",
      "hook_event_name": "Stop",
      "transcript_path": "/Users/test/.claude/projects/abc/transcript.jsonl"
    }
    """.data(using: .utf8)!

    let event = try JSONDecoder().decode(HookEventBase.self, from: data)
    #expect(event.transcriptPath == "/Users/test/.claude/projects/abc/transcript.jsonl")
}

@Test func hookEventBaseTranscriptPathIsOptional() throws {
    let data = """
    {
      "session_id": "session-tp2",
      "cwd": "/tmp/project",
      "hook_event_name": "Stop"
    }
    """.data(using: .utf8)!

    let event = try JSONDecoder().decode(HookEventBase.self, from: data)
    #expect(event.transcriptPath == nil)
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift test --filter hookEventBaseDecodesTranscriptPath`
Expected: FAIL — `transcriptPath` property doesn't exist

**Step 3: Add transcriptPath to HookEventBase**

In `WorkforceKit/Sources/WorkforceKit/Models/HookEvent.swift`, add to `HookEventBase`:

```swift
public let transcriptPath: String?

enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case cwd
    case hookEventName = "hook_event_name"
    case transcriptPath = "transcript_path"
}
```

**Step 4: Run all tests**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift test`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add WorkforceKit/Sources/WorkforceKit/Models/HookEvent.swift \
        WorkforceKit/Tests/WorkforceKitTests/WorkforceKitTests.swift
git commit -m "feat: add transcript_path field to HookEventBase"
```

---

## Task 3: Add TranscriptParser to WorkforceKit

**Files:**
- Create: `WorkforceKit/Sources/WorkforceKit/TranscriptParser.swift`
- Modify: `WorkforceKit/Tests/WorkforceKitTests/WorkforceKitTests.swift`

The transcript parser reads a Claude Code JSONL transcript file and sums all token usage.

**Step 1: Write failing test**

Add to `WorkforceKit/Tests/WorkforceKitTests/WorkforceKitTests.swift`:

```swift
@Test func transcriptParserSumsTokenUsageFromJSONL() throws {
    let lines = [
        #"{"type":"human","message":{"role":"user","content":"hello"},"uuid":"1"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":"hi","usage":{"input_tokens":100,"output_tokens":50}},"uuid":"2"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":"done","usage":{"input_tokens":200,"output_tokens":75,"cache_creation_input_tokens":10,"cache_read_input_tokens":20}},"uuid":"3"}"#,
    ]
    let content = lines.joined(separator: "\n")
    let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("test-transcript-\(UUID()).jsonl")
    try content.write(to: tmpFile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmpFile) }

    let usage = TranscriptParser.parseTokenUsage(from: tmpFile.path)

    #expect(usage.inputTokens == 300)
    #expect(usage.outputTokens == 125)
    #expect(usage.cacheCreationTokens == 10)
    #expect(usage.cacheReadTokens == 20)
}

@Test func transcriptParserReturnsZerosForMissingFile() throws {
    let usage = TranscriptParser.parseTokenUsage(from: "/nonexistent/path.jsonl")
    #expect(usage.inputTokens == 0)
    #expect(usage.outputTokens == 0)
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift test --filter transcriptParser`
Expected: FAIL — `TranscriptParser` doesn't exist

**Step 3: Implement TranscriptParser**

Create `WorkforceKit/Sources/WorkforceKit/TranscriptParser.swift`:

```swift
import Foundation

public struct TokenUsageSummary: Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
}

public enum TranscriptParser {
    /// Parse a Claude Code transcript JSONL file and sum all token usage.
    public static func parseTokenUsage(from path: String) -> TokenUsageSummary {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return TokenUsageSummary(inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0)
        }

        var totalInput = 0
        var totalOutput = 0
        var totalCacheCreation = 0
        var totalCacheRead = 0

        for line in content.split(separator: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }

            totalInput += usage["input_tokens"] as? Int ?? 0
            totalOutput += usage["output_tokens"] as? Int ?? 0
            totalCacheCreation += usage["cache_creation_input_tokens"] as? Int ?? 0
            totalCacheRead += usage["cache_read_input_tokens"] as? Int ?? 0
        }

        return TokenUsageSummary(
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheCreationTokens: totalCacheCreation,
            cacheReadTokens: totalCacheRead
        )
    }
}
```

**Step 4: Run all tests**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift test`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add WorkforceKit/Sources/WorkforceKit/TranscriptParser.swift \
        WorkforceKit/Tests/WorkforceKitTests/WorkforceKitTests.swift
git commit -m "feat: add TranscriptParser for reading token usage from JSONL transcripts"
```

---

## Task 4: Update StopCommand and SessionEndCommand to send token data

**Files:**
- Modify: `WorkforceKit/Sources/WorkforceCLI/Commands/StopCommand.swift`
- Modify: `WorkforceKit/Sources/WorkforceCLI/Commands/SessionEndCommand.swift`

**Step 1: Update StopCommand to parse transcript and send tokens**

Replace `WorkforceKit/Sources/WorkforceCLI/Commands/StopCommand.swift` with:

```swift
import ArgumentParser
import Foundation
import WorkforceKit

struct StopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Handle Stop hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(HookEventBase.self, from: data)
        let sessionId = resolveSessionId(from: event.sessionId)

        // Send idle status update
        SocketClient.send(SocketMessage(
            type: .updateStatus,
            sessionId: sessionId,
            cwd: event.cwd,
            status: .idle
        ))

        // Parse transcript for token usage and send update
        if let transcriptPath = event.transcriptPath {
            let usage = TranscriptParser.parseTokenUsage(from: transcriptPath)
            if usage.inputTokens > 0 || usage.outputTokens > 0 {
                SocketClient.send(SocketMessage(
                    type: .updateTokens,
                    sessionId: sessionId,
                    cwd: event.cwd,
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens,
                    cacheCreationTokens: usage.cacheCreationTokens,
                    cacheReadTokens: usage.cacheReadTokens
                ))
            }
        }
    }
}
```

**Step 2: Update SessionEndCommand similarly**

Replace `WorkforceKit/Sources/WorkforceCLI/Commands/SessionEndCommand.swift` with:

```swift
import ArgumentParser
import Foundation
import WorkforceKit

struct SessionEndCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session-end",
        abstract: "Handle SessionEnd hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(HookEventBase.self, from: data)
        let sessionId = resolveSessionId(from: event.sessionId)

        // Send final token update before deregistering
        if let transcriptPath = event.transcriptPath {
            let usage = TranscriptParser.parseTokenUsage(from: transcriptPath)
            if usage.inputTokens > 0 || usage.outputTokens > 0 {
                SocketClient.send(SocketMessage(
                    type: .updateTokens,
                    sessionId: sessionId,
                    cwd: event.cwd,
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens,
                    cacheCreationTokens: usage.cacheCreationTokens,
                    cacheReadTokens: usage.cacheReadTokens
                ))
            }
        }

        SocketClient.send(SocketMessage(
            type: .deregister,
            sessionId: sessionId,
            cwd: event.cwd
        ))
    }
}
```

**Step 3: Build the CLI to verify compilation**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift build`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add WorkforceKit/Sources/WorkforceCLI/Commands/StopCommand.swift \
        WorkforceKit/Sources/WorkforceCLI/Commands/SessionEndCommand.swift
git commit -m "feat: parse transcript token usage in Stop and SessionEnd hooks"
```

---

## Task 5: Handle updateTokens in AgentStore (app side)

**Files:**
- Modify: `Workforce/Workforce/Models/SocketMessage.swift` (app-side copy)
- Modify: `Workforce/Workforce/Models/Agent.swift` (app-side copy)
- Modify: `Workforce/Workforce/Services/AgentStore.swift`

Note: The app has its own copies of the models in `Workforce/Workforce/Models/`. These need the same changes as the WorkforceKit versions.

**Step 1: Add updateTokens case and token fields to app-side SocketMessage**

In `Workforce/Workforce/Models/SocketMessage.swift`, add `case updateTokens` to `SocketMessageType` and add the four optional token fields + init params, matching what was done in Task 1.

**Step 2: Add token fields to app-side Agent**

In `Workforce/Workforce/Models/Agent.swift`, add the four `total*Tokens` fields (defaulting to 0), matching Task 1.

**Step 3: Handle .updateTokens in AgentStore.handleMessage**

In `Workforce/Workforce/Services/AgentStore.swift`, add a new case in `handleMessage`:

```swift
case .updateTokens:
    var agent = ensureAgent(for: message)
    agent.lastActivityAt = message.timestamp
    // Token updates are cumulative totals from the transcript, not deltas
    if let input = message.inputTokens { agent.totalInputTokens = input }
    if let output = message.outputTokens { agent.totalOutputTokens = output }
    if let cacheCreation = message.cacheCreationTokens { agent.totalCacheCreationTokens = cacheCreation }
    if let cacheRead = message.cacheReadTokens { agent.totalCacheReadTokens = cacheRead }
    agents[message.sessionId] = agent
```

**Step 4: Build the Xcode project to verify**

Open `Workforce/Workforce.xcodeproj` in Xcode and build, or verify no errors with `xcodebuild -project Workforce/Workforce.xcodeproj -scheme Workforce build`.

**Step 5: Commit**

```bash
git add Workforce/Workforce/Models/SocketMessage.swift \
        Workforce/Workforce/Models/Agent.swift \
        Workforce/Workforce/Services/AgentStore.swift
git commit -m "feat: handle updateTokens messages in AgentStore"
```

---

## Task 6: Add CostCalculator utility

**Files:**
- Create: `Workforce/Workforce/Services/CostCalculator.swift`

**Step 1: Create CostCalculator**

```swift
import Foundation

enum CostCalculator {
    struct ModelPricing {
        let inputPerMillion: Double
        let outputPerMillion: Double
    }

    // Pricing as of 2026-02 (USD per million tokens)
    private static let pricing: [String: ModelPricing] = [
        "claude-opus-4-6": ModelPricing(inputPerMillion: 15.0, outputPerMillion: 75.0),
        "claude-sonnet-4-6": ModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0),
        "claude-haiku-4-5": ModelPricing(inputPerMillion: 0.80, outputPerMillion: 4.0),
        // Fallback for unknown models
    ]

    private static let defaultPricing = ModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0)

    static func estimateCost(
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0
    ) -> Double {
        let p = pricing[model ?? ""] ?? defaultPricing
        let inputCost = Double(inputTokens) / 1_000_000.0 * p.inputPerMillion
        let outputCost = Double(outputTokens) / 1_000_000.0 * p.outputPerMillion
        // Cache creation costs 25% more than input, cache reads cost 90% less
        let cacheCreateCost = Double(cacheCreationTokens) / 1_000_000.0 * p.inputPerMillion * 1.25
        let cacheReadCost = Double(cacheReadTokens) / 1_000_000.0 * p.inputPerMillion * 0.1
        return inputCost + outputCost + cacheCreateCost + cacheReadCost
    }

    static func formatCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return "<$0.01"
        }
        return String(format: "$%.2f", cost)
    }

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }
}
```

**Step 2: Build to verify**

Build the Xcode project.

**Step 3: Commit**

```bash
git add Workforce/Workforce/Services/CostCalculator.swift
git commit -m "feat: add CostCalculator for token cost estimation"
```

---

## Task 7: Add cost badges to sidebar

**Files:**
- Modify: `Workforce/Workforce/Views/AgentRowView.swift`
- Modify: `Workforce/Workforce/Views/MainWindowView.swift`

**Step 1: Add cost label to AgentRowView**

In `Workforce/Workforce/Views/AgentRowView.swift`, add a cost label before the `PulsingDot`. Between `Spacer()` and `PulsingDot`:

```swift
if agent.totalInputTokens > 0 || agent.totalOutputTokens > 0 {
    let cost = CostCalculator.estimateCost(
        model: agent.model,
        inputTokens: agent.totalInputTokens,
        outputTokens: agent.totalOutputTokens,
        cacheCreationTokens: agent.totalCacheCreationTokens,
        cacheReadTokens: agent.totalCacheReadTokens
    )
    Text(CostCalculator.formatCost(cost))
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
}
```

**Step 2: Add aggregate cost to folder section header**

In `MainWindowView.swift`, in the `sectionHeader(for:)` method, add a cost badge after `Spacer()` and before the `Menu` (+) button. Compute the sum of all agents in that folder:

```swift
let folderCost = agents(for: cwd).reduce(0.0) { total, agent in
    total + CostCalculator.estimateCost(
        model: agent.model,
        inputTokens: agent.totalInputTokens,
        outputTokens: agent.totalOutputTokens,
        cacheCreationTokens: agent.totalCacheCreationTokens,
        cacheReadTokens: agent.totalCacheReadTokens
    )
}
if folderCost > 0 {
    Text(CostCalculator.formatCost(folderCost))
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
}
```

**Step 3: Update footer to show aggregate cost**

In `MainWindowView.swift`, update the `footer` computed property:

```swift
private var footer: some View {
    HStack {
        let totalCost = store.sortedAgents.reduce(0.0) { total, agent in
            total + CostCalculator.estimateCost(
                model: agent.model,
                inputTokens: agent.totalInputTokens,
                outputTokens: agent.totalOutputTokens,
                cacheCreationTokens: agent.totalCacheCreationTokens,
                cacheReadTokens: agent.totalCacheReadTokens
            )
        }
        Text("\(store.agents.count) agent\(store.agents.count == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(.secondary)
        if totalCost > 0 {
            Text("·")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(CostCalculator.formatCost(totalCost))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
}
```

**Step 4: Build and verify visually**

Build the Xcode project. Launch the app and verify the sidebar renders without errors.

**Step 5: Commit**

```bash
git add Workforce/Workforce/Views/AgentRowView.swift \
        Workforce/Workforce/Views/MainWindowView.swift
git commit -m "feat: add cost badges to agent rows, folder headers, and footer"
```

---

## Task 8: Add GitService for project git info

**Files:**
- Create: `Workforce/Workforce/Services/GitService.swift`

**Step 1: Create GitService**

```swift
import Foundation

struct GitInfo {
    let branch: String
    let dirtyFileCount: Int
    let recentCommits: [GitCommit]
}

struct GitCommit: Identifiable {
    let id: String  // short hash
    let message: String
}

enum GitService {
    private static let gitPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/usr/bin/git",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func fetchInfo(for path: String) -> GitInfo? {
        guard let git = gitPath else { return nil }

        // Check if it's a git repo
        let headResult = runGit(git, args: ["rev-parse", "--abbrev-ref", "HEAD"], cwd: path)
        guard headResult.status == 0 else { return nil }
        let branch = headResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Dirty file count
        let statusResult = runGit(git, args: ["status", "--porcelain"], cwd: path)
        let dirtyCount = statusResult.status == 0
            ? statusResult.output.split(separator: "\n").count
            : 0

        // Recent commits
        let logResult = runGit(git, args: ["log", "--oneline", "-10", "--no-decorate"], cwd: path)
        let commits: [GitCommit] = logResult.status == 0
            ? logResult.output.split(separator: "\n").compactMap { line in
                let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard parts.count == 2 else { return nil }
                return GitCommit(id: String(parts[0]), message: String(parts[1]))
            }
            : []

        return GitInfo(branch: branch, dirtyFileCount: dirtyCount, recentCommits: commits)
    }

    private static func runGit(_ gitPath: String, args: [String], cwd: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (1, "")
        }
    }
}
```

**Step 2: Build to verify**

Build the Xcode project.

**Step 3: Commit**

```bash
git add Workforce/Workforce/Services/GitService.swift
git commit -m "feat: add GitService for fetching project git info"
```

---

## Task 9: Create ProjectDetailView

**Files:**
- Create: `Workforce/Workforce/Views/ProjectDetailView.swift`

**Step 1: Create the view with three tabs**

```swift
import SwiftUI

struct ProjectDetailView: View {
    let cwd: String
    let store: AgentStore
    let eventLog: EventLog
    @State private var selectedTab = 0
    @State private var gitInfo: GitInfo?

    private var projectAgents: [Agent] {
        store.sortedAgents.filter { $0.cwd == cwd }
    }

    private var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                Text(projectName)
                    .font(.headline)
                Spacer()
                Text("\(projectAgents.count) agent\(projectAgents.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Tab picker
            Picker("", selection: $selectedTab) {
                Text("Stats").tag(0)
                Text("Git").tag(1)
                Text("Activity").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Tab content
            switch selectedTab {
            case 0:
                statsTab
            case 1:
                gitTab
            case 2:
                activityTab
            default:
                EmptyView()
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await refreshGitInfo()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await refreshGitInfo()
            }
        }
    }

    // MARK: - Stats Tab

    private var statsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Summary cards
                let totalInput = projectAgents.reduce(0) { $0 + $1.totalInputTokens }
                let totalOutput = projectAgents.reduce(0) { $0 + $1.totalOutputTokens }
                let totalCost = projectAgents.reduce(0.0) { total, agent in
                    total + CostCalculator.estimateCost(
                        model: agent.model,
                        inputTokens: agent.totalInputTokens,
                        outputTokens: agent.totalOutputTokens,
                        cacheCreationTokens: agent.totalCacheCreationTokens,
                        cacheReadTokens: agent.totalCacheReadTokens
                    )
                }

                HStack(spacing: 16) {
                    StatCard(title: "Total Tokens", value: CostCalculator.formatTokens(totalInput + totalOutput))
                    StatCard(title: "Estimated Cost", value: CostCalculator.formatCost(totalCost))
                    StatCard(title: "Active", value: "\(projectAgents.filter { $0.status == .active }.count)")
                }

                // Per-agent breakdown
                if !projectAgents.isEmpty {
                    Text("Per Agent")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(projectAgents) { agent in
                        HStack {
                            Text(agent.displayTitle)
                                .font(.body)
                            if let model = agent.model {
                                Text(model)
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.quaternary)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                            Spacer()
                            let tokens = agent.totalInputTokens + agent.totalOutputTokens
                            if tokens > 0 {
                                Text(CostCalculator.formatTokens(tokens))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                let cost = CostCalculator.estimateCost(
                                    model: agent.model,
                                    inputTokens: agent.totalInputTokens,
                                    outputTokens: agent.totalOutputTokens,
                                    cacheCreationTokens: agent.totalCacheCreationTokens,
                                    cacheReadTokens: agent.totalCacheReadTokens
                                )
                                Text(CostCalculator.formatCost(cost))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Git Tab

    private var gitTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let info = gitInfo {
                    HStack {
                        Label(info.branch, systemImage: "arrow.triangle.branch")
                            .font(.body.weight(.medium))
                        Spacer()
                        if info.dirtyFileCount > 0 {
                            Text("\(info.dirtyFileCount) uncommitted")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    if !info.recentCommits.isEmpty {
                        Text("Recent Commits")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(info.recentCommits) { commit in
                            HStack(alignment: .top, spacing: 8) {
                                Text(commit.id)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(commit.message)
                                    .font(.caption)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } else {
                    Text("Not a git repository")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    // MARK: - Activity Tab

    private var activityTab: some View {
        let projectEntries = Array(
            eventLog.entries
                .reversed()
                .filter { $0.message?.cwd == cwd }
                .prefix(100)
        )

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if projectEntries.isEmpty {
                    Text("No recent activity")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(projectEntries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            if let message = entry.message {
                                Circle()
                                    .fill(message.type.badgeColor)
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 5)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                if let message = entry.message {
                                    Text(activityTitle(for: message))
                                        .font(.caption.weight(.medium))
                                }
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func activityTitle(for message: SocketMessage) -> String {
        switch message.type {
        case .updateTool:
            return "Tool: \(message.toolName ?? "unknown")"
        case .updateStatus:
            return "Status: \(message.status?.rawValue ?? "updated")"
        case .notification:
            return "Notification: \(message.notificationType ?? "event")"
        case .register:
            return "Agent registered"
        case .deregister:
            return "Agent deregistered"
        case .subagentStart:
            return "Subagent started"
        case .subagentStop:
            return "Subagent stopped"
        case .updateTokens:
            return "Token update"
        }
    }

    @MainActor
    private func refreshGitInfo() async {
        gitInfo = GitService.fetchInfo(for: cwd)
    }
}

private struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
```

**Step 2: Build to verify**

Build the Xcode project.

**Step 3: Commit**

```bash
git add Workforce/Workforce/Views/ProjectDetailView.swift
git commit -m "feat: add ProjectDetailView with stats, git, and activity tabs"
```

---

## Task 10: Wire up folder selection in MainWindowView

**Files:**
- Modify: `Workforce/Workforce/Views/MainWindowView.swift`

This is the integration task. We add `selectedFolderCwd` state, make the folder header selectable (clicking the icon/name selects the folder, chevron still toggles collapse), and switch the right pane between terminal and project detail.

**Step 1: Add selectedFolderCwd state**

At the top of `MainWindowView`, add:

```swift
@State private var selectedFolderCwd: String?
```

**Step 2: Update selection logic**

When an agent is selected (`selectedAgentId` is set), clear `selectedFolderCwd`. When a folder is selected, clear `selectedAgentId`.

Modify the agent row `onTapGesture`:
```swift
.onTapGesture {
    selectedAgentId = agent.sessionId
    selectedFolderCwd = nil
}
```

**Step 3: Make folder header name/icon area selectable**

In `sectionHeader(for:)`, split the header into two tap zones:
- Chevron: toggles collapse (existing behavior)
- Folder icon + name: selects the folder for the detail panel

Replace the existing `.onTapGesture` on the whole header. The chevron should have its own tap gesture for collapse/expand, and the remaining area should select the folder:

```swift
// On the folder icon + text HStack:
.onTapGesture {
    selectedFolderCwd = cwd
    selectedAgentId = nil
}

// On the chevron only:
.onTapGesture {
    withAnimation(.easeInOut(duration: 0.15)) {
        if collapsedCwds.contains(cwd) {
            collapsedCwds.remove(cwd)
        } else {
            collapsedCwds.insert(cwd)
        }
    }
}
```

Add a selected background to the header when `selectedFolderCwd == cwd`:

```swift
.background(
    selectedFolderCwd == cwd
        ? Color.accentColor.opacity(0.1)
        : Color(nsColor: .controlBackgroundColor).opacity(0.5)
)
```

**Step 4: Switch right pane based on selection**

Replace the `terminalPane` usage in `body` with a conditional:

```swift
// In the HSplitView, replace `terminalPane` with:
Group {
    if selectedFolderCwd != nil, selectedAgentId == nil {
        ProjectDetailView(
            cwd: selectedFolderCwd!,
            store: store,
            eventLog: eventLog
        )
    } else {
        terminalPane
    }
}
```

**Step 5: Build and test visually**

Build the Xcode project. Launch, click a folder name — should show the project detail panel. Click an agent — should show the terminal. Click the chevron — should toggle collapse without changing the right pane.

**Step 6: Commit**

```bash
git add Workforce/Workforce/Views/MainWindowView.swift
git commit -m "feat: wire up folder selection to show ProjectDetailView in right pane"
```

---

## Task 11: Add badgeColor to SocketMessageType (if missing in app)

**Files:**
- Check: `Workforce/Workforce/Models/SocketMessage.swift`

The `ProjectDetailView` references `message.type.badgeColor`. Check if this extension already exists in the app. If the `badgeColor` property exists on `SocketMessageType`, just add the `case .updateTokens` to it. If not, add the extension.

**Step 1: Add updateTokens case to badgeColor**

Ensure the `badgeColor` computed property on `SocketMessageType` has a case for `.updateTokens`:

```swift
case .updateTokens: .blue
```

**Step 2: Build**

Build the Xcode project.

**Step 3: Commit (if changes were needed)**

```bash
git add Workforce/Workforce/Models/SocketMessage.swift
git commit -m "fix: add updateTokens case to badgeColor extension"
```

---

## Task 12: Final integration test

**Step 1: Run WorkforceKit tests**

Run: `cd /Users/timbroddin/Projects/workforce/WorkforceKit && swift test`
Expected: ALL PASS

**Step 2: Build the Xcode project**

Build the full app in Xcode. Verify no warnings or errors.

**Step 3: Manual smoke test**

1. Launch the app
2. Start a Claude Code session in a project folder
3. Verify the agent appears in the sidebar
4. Do some work — verify cost badge appears on the agent row after Claude stops
5. Click the folder name — verify the project detail panel appears with Stats/Git/Activity tabs
6. Click back on an agent — verify the terminal reappears
7. Check the Git tab shows correct branch and commit info
8. Check the Activity tab shows recent events

**Step 4: Commit any final fixes**

```bash
git add -A
git commit -m "feat: enhanced project dashboard with token tracking and project detail panel"
```
