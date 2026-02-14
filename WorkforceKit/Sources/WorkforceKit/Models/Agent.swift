import Foundation

public enum AgentStatus: String, Codable, Sendable {
    case active
    case waitingForInput
    case waitingForPermission
    case idle
    case stopped
}

public enum HostApp: String, Codable, Sendable {
    case terminal
    case iterm
    case vscode
    case cursor
    case warp
    case unknown
}

public struct Agent: Codable, Identifiable, Sendable {
    public let sessionId: String
    public var id: String { sessionId }

    public let name: String
    public let avatarSeed: String

    public let cwd: String
    public let hostApp: HostApp
    public let hostBundleId: String?
    public let hostPid: Int32?

    public let startedAt: Date
    public var lastActivityAt: Date
    public var status: AgentStatus
    public var currentToolName: String?
    public var lastNotificationType: String?
    public var subagentCount: Int

    public init(
        sessionId: String,
        name: String,
        avatarSeed: String,
        cwd: String,
        hostApp: HostApp,
        hostBundleId: String?,
        hostPid: Int32?,
        startedAt: Date = Date(),
        lastActivityAt: Date = Date(),
        status: AgentStatus = .active,
        currentToolName: String? = nil,
        lastNotificationType: String? = nil,
        subagentCount: Int = 0
    ) {
        self.sessionId = sessionId
        self.name = name
        self.avatarSeed = avatarSeed
        self.cwd = cwd
        self.hostApp = hostApp
        self.hostBundleId = hostBundleId
        self.hostPid = hostPid
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.status = status
        self.currentToolName = currentToolName
        self.lastNotificationType = lastNotificationType
        self.subagentCount = subagentCount
    }
}
