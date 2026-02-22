import Foundation
import SwiftUI

public enum SocketMessageType: String, Codable, Sendable, CaseIterable {
    case register
    case updateStatus
    case updateTool
    case notification
    case subagentStart
    case subagentStop
    case deregister
    case updateTokens

    var badgeColor: Color {
        switch self {
        case .register: .green
        case .deregister: .red
        case .updateTool: .blue
        case .updateStatus: .gray
        case .notification: .orange
        case .subagentStart: .purple
        case .subagentStop: .purple
        case .updateTokens: .blue
        }
    }
}

public struct SocketMessage: Codable, Sendable {
    public let type: SocketMessageType
    public let sessionId: String
    public let cwd: String
    public let timestamp: Date

    // Registration fields (only for .register)
    public var name: String?
    public var avatarSeed: String?

    public var model: String?

    // Status update fields
    public var status: AgentStatus?
    public var toolName: String?
    public var notificationType: String?
    public var agentType: String?
    public var tmuxSession: String?

    // Token tracking fields (only for .updateTokens)
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheCreationTokens: Int?
    public var cacheReadTokens: Int?

    // Notification context fields
    public var transcriptPath: String?

    public init(
        type: SocketMessageType,
        sessionId: String,
        cwd: String,
        timestamp: Date = Date(),
        name: String? = nil,
        avatarSeed: String? = nil,
        model: String? = nil,
        status: AgentStatus? = nil,
        toolName: String? = nil,
        notificationType: String? = nil,
        agentType: String? = nil,
        tmuxSession: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        transcriptPath: String? = nil
    ) {
        self.type = type
        self.sessionId = sessionId
        self.cwd = cwd
        self.timestamp = timestamp
        self.name = name
        self.avatarSeed = avatarSeed
        self.model = model
        self.status = status
        self.toolName = toolName
        self.notificationType = notificationType
        self.agentType = agentType
        self.tmuxSession = tmuxSession
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.transcriptPath = transcriptPath
    }
}
