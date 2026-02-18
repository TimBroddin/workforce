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
