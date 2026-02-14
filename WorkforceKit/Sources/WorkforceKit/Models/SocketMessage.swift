import Foundation

public enum SocketMessageType: String, Codable, Sendable {
    case register
    case updateStatus
    case updateTool
    case notification
    case subagentStart
    case subagentStop
    case deregister
}

public struct SocketMessage: Codable, Sendable {
    public let type: SocketMessageType
    public let sessionId: String
    public let cwd: String
    public let timestamp: Date

    // Registration fields (only for .register)
    public var name: String?
    public var avatarSeed: String?
    public var hostApp: HostApp?
    public var hostBundleId: String?
    public var hostPid: Int32?

    public var model: String?

    // Status update fields
    public var status: AgentStatus?
    public var toolName: String?
    public var notificationType: String?
    public var agentType: String?
    public var tmuxSession: String?

    public init(
        type: SocketMessageType,
        sessionId: String,
        cwd: String,
        timestamp: Date = Date(),
        name: String? = nil,
        avatarSeed: String? = nil,
        hostApp: HostApp? = nil,
        hostBundleId: String? = nil,
        hostPid: Int32? = nil,
        model: String? = nil,
        status: AgentStatus? = nil,
        toolName: String? = nil,
        notificationType: String? = nil,
        agentType: String? = nil,
        tmuxSession: String? = nil
    ) {
        self.type = type
        self.sessionId = sessionId
        self.cwd = cwd
        self.timestamp = timestamp
        self.name = name
        self.avatarSeed = avatarSeed
        self.hostApp = hostApp
        self.hostBundleId = hostBundleId
        self.hostPid = hostPid
        self.model = model
        self.status = status
        self.toolName = toolName
        self.notificationType = notificationType
        self.agentType = agentType
        self.tmuxSession = tmuxSession
    }
}
