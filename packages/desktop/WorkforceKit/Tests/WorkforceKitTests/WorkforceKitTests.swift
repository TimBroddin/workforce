import Foundation
import Testing
@testable import WorkforceKit

@Test func hookEventBaseDecodesSnakeCaseFields() throws {
    let data = """
    {
      "session_id": "session-1",
      "cwd": "/tmp/project",
      "hook_event_name": "SessionStart"
    }
    """.data(using: .utf8)!

    let event = try JSONDecoder().decode(HookEventBase.self, from: data)
    #expect(event.sessionId == "session-1")
    #expect(event.cwd == "/tmp/project")
    #expect(event.hookEventName == "SessionStart")
}

@Test func toolUseEventDecodesOptionalToolInput() throws {
    let data = """
    {
      "session_id": "session-2",
      "cwd": "/tmp/project",
      "hook_event_name": "PreToolUse",
      "tool_name": "bash",
      "tool_input": {
        "command": "ls -la",
        "file_path": "/tmp/project"
      }
    }
    """.data(using: .utf8)!

    let event = try JSONDecoder().decode(ToolUseEvent.self, from: data)
    #expect(event.toolName == "bash")
    #expect(event.toolInput?.command == "ls -la")
    #expect(event.toolInput?.filePath == "/tmp/project")
}

@Test func notificationEventTypeIsNilWhenMissing() throws {
    let data = """
    {
      "session_id": "session-3",
      "cwd": "/tmp/project",
      "hook_event_name": "Notification"
    }
    """.data(using: .utf8)!

    let event = try JSONDecoder().decode(NotificationEvent.self, from: data)
    #expect(event.type == nil)
}

@Test func socketMessageRoundTripPreservesPayload() throws {
    let timestamp = Date(timeIntervalSince1970: 1_735_689_600)
    let message = SocketMessage(
        type: .updateTool,
        sessionId: "session-4",
        cwd: "/tmp/project",
        timestamp: timestamp,
        name: "Bright Otter",
        avatarSeed: "seed-4",
        model: "gpt-5",
        status: .active,
        toolName: "bash",
        notificationType: "task_complete",
        agentType: "claude",
        tmuxSession: "workforce-session-4"
    )

    let encoded = try JSONEncoder().encode(message)
    let decoded = try JSONDecoder().decode(SocketMessage.self, from: encoded)

    #expect(decoded.type == .updateTool)
    #expect(decoded.sessionId == "session-4")
    #expect(decoded.cwd == "/tmp/project")
    #expect(decoded.name == "Bright Otter")
    #expect(decoded.avatarSeed == "seed-4")
    #expect(decoded.model == "gpt-5")
    #expect(decoded.status == .active)
    #expect(decoded.toolName == "bash")
    #expect(decoded.notificationType == "task_complete")
    #expect(decoded.agentType == "claude")
    #expect(decoded.tmuxSession == "workforce-session-4")
    #expect(decoded.timestamp == timestamp)
}

@Test func agentRoundTripPreservesCoreFieldsAndIdentity() throws {
    let startedAt = Date(timeIntervalSince1970: 1_735_689_700)
    let lastActivityAt = Date(timeIntervalSince1970: 1_735_689_900)

    let agent = Agent(
        sessionId: "session-5",
        name: "Swift Falcon",
        avatarSeed: "seed-5",
        cwd: "/tmp/project",
        agentType: "claude",
        model: "gpt-5",
        tmuxSession: "workforce-session-5",
        startedAt: startedAt,
        lastActivityAt: lastActivityAt,
        status: .waitingForInput,
        currentToolName: "read_file",
        lastNotificationType: "approval_request",
        subagentCount: 2
    )

    let encoded = try JSONEncoder().encode(agent)
    let decoded = try JSONDecoder().decode(Agent.self, from: encoded)

    #expect(decoded.sessionId == "session-5")
    #expect(decoded.id == decoded.sessionId)
    #expect(decoded.name == "Swift Falcon")
    #expect(decoded.avatarSeed == "seed-5")
    #expect(decoded.cwd == "/tmp/project")
    #expect(decoded.agentType == "claude")
    #expect(decoded.model == "gpt-5")
    #expect(decoded.tmuxSession == "workforce-session-5")
    #expect(decoded.startedAt == startedAt)
    #expect(decoded.lastActivityAt == lastActivityAt)
    #expect(decoded.status == .waitingForInput)
    #expect(decoded.currentToolName == "read_file")
    #expect(decoded.lastNotificationType == "approval_request")
    #expect(decoded.subagentCount == 2)
}

@Test func socketMessageRoundTripPreservesTokenFields() throws {
    let timestamp = Date(timeIntervalSince1970: 1_735_689_600)
    let message = SocketMessage(
        type: .updateTokens,
        sessionId: "session-6",
        cwd: "/tmp/project",
        timestamp: timestamp,
        inputTokens: 1500,
        outputTokens: 800,
        cacheCreationTokens: 200,
        cacheReadTokens: 3000
    )

    let encoded = try JSONEncoder().encode(message)
    let decoded = try JSONDecoder().decode(SocketMessage.self, from: encoded)

    #expect(decoded.type == .updateTokens)
    #expect(decoded.sessionId == "session-6")
    #expect(decoded.cwd == "/tmp/project")
    #expect(decoded.timestamp == timestamp)
    #expect(decoded.inputTokens == 1500)
    #expect(decoded.outputTokens == 800)
    #expect(decoded.cacheCreationTokens == 200)
    #expect(decoded.cacheReadTokens == 3000)
}

@Test func agentTokenFieldsDefaultToZeroAndRoundTrip() throws {
    let startedAt = Date(timeIntervalSince1970: 1_735_690_000)

    // Verify defaults are 0
    let agentDefaults = Agent(
        sessionId: "session-7",
        name: "Token Tracker",
        avatarSeed: "seed-7",
        cwd: "/tmp/project"
    )
    #expect(agentDefaults.totalInputTokens == 0)
    #expect(agentDefaults.totalOutputTokens == 0)
    #expect(agentDefaults.totalCacheCreationTokens == 0)
    #expect(agentDefaults.totalCacheReadTokens == 0)

    // Verify round-trip with non-zero values
    let agent = Agent(
        sessionId: "session-8",
        name: "Token Tracker",
        avatarSeed: "seed-8",
        cwd: "/tmp/project",
        startedAt: startedAt,
        totalInputTokens: 5000,
        totalOutputTokens: 2500,
        totalCacheCreationTokens: 1000,
        totalCacheReadTokens: 8000
    )

    let encoded = try JSONEncoder().encode(agent)
    let decoded = try JSONDecoder().decode(Agent.self, from: encoded)

    #expect(decoded.totalInputTokens == 5000)
    #expect(decoded.totalOutputTokens == 2500)
    #expect(decoded.totalCacheCreationTokens == 1000)
    #expect(decoded.totalCacheReadTokens == 8000)
}

@Test func hookEventBaseDecodesTranscriptPath() throws {
    let data = """
    {
      "session_id": "session-tp-1",
      "cwd": "/tmp/project",
      "hook_event_name": "SessionStart",
      "transcript_path": "/Users/test/.claude/sessions/session-tp-1.jsonl"
    }
    """.data(using: .utf8)!

    let event = try JSONDecoder().decode(HookEventBase.self, from: data)
    #expect(event.sessionId == "session-tp-1")
    #expect(event.transcriptPath == "/Users/test/.claude/sessions/session-tp-1.jsonl")
}

@Test func hookEventBaseTranscriptPathIsOptional() throws {
    let data = """
    {
      "session_id": "session-tp-2",
      "cwd": "/tmp/project",
      "hook_event_name": "SessionStart"
    }
    """.data(using: .utf8)!

    let event = try JSONDecoder().decode(HookEventBase.self, from: data)
    #expect(event.transcriptPath == nil)
}

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
