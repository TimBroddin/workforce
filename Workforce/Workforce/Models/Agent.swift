import Foundation

public enum AgentStatus: String, Codable, Sendable {
    case active
    case waitingForInput
    case waitingForPermission
    case idle
    case stopped
}

public struct Agent: Codable, Identifiable, Sendable {
    public let sessionId: String
    public var id: String { sessionId }

    public let name: String
    public let avatarSeed: String

    public let cwd: String

    public let agentType: String
    public let model: String?
    public let tmuxSession: String?

    public let startedAt: Date
    public var lastActivityAt: Date
    public var status: AgentStatus
    public var currentToolName: String?
    public var lastNotificationType: String?
    public var subagentCount: Int
    public var paneTitle: String?

    public init(
        sessionId: String,
        name: String,
        avatarSeed: String,
        cwd: String,
        agentType: String = "claude",
        model: String? = nil,
        tmuxSession: String? = nil,
        startedAt: Date = Date(),
        lastActivityAt: Date = Date(),
        status: AgentStatus = .active,
        currentToolName: String? = nil,
        lastNotificationType: String? = nil,
        subagentCount: Int = 0,
        paneTitle: String? = nil
    ) {
        self.sessionId = sessionId
        self.name = name
        self.avatarSeed = avatarSeed
        self.cwd = cwd
        self.agentType = agentType
        self.model = model
        self.tmuxSession = tmuxSession
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.status = status
        self.currentToolName = currentToolName
        self.lastNotificationType = lastNotificationType
        self.subagentCount = subagentCount
        self.paneTitle = paneTitle
    }
}
