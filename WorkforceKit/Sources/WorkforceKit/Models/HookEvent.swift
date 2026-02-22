import Foundation

/// Common fields present in every hook event's stdin JSON
public struct HookEventBase: Decodable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let hookEventName: String
    public let transcriptPath: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case transcriptPath = "transcript_path"
    }
}

/// PreToolUse / PostToolUse / PostToolUseFailure event
public struct ToolUseEvent: Decodable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let hookEventName: String
    public let toolName: String
    public let toolInput: ToolInput?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case toolInput = "tool_input"
    }

    public struct ToolInput: Decodable, Sendable {
        public let command: String?
        public let filePath: String?

        enum CodingKeys: String, CodingKey {
            case command
            case filePath = "file_path"
        }
    }
}

/// Notification event
public struct NotificationEvent: Decodable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let hookEventName: String
    public let type: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case type
    }
}

/// SubagentStart / SubagentStop event
public struct SubagentEvent: Decodable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let hookEventName: String
    public let agentType: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case agentType = "agent_type"
    }
}
