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
    public let host: String?

    public let startedAt: Date
    public var lastActivityAt: Date
    public var status: AgentStatus
    public var currentToolName: String?
    public var lastNotificationType: String?
    public var subagentCount: Int
    public var paneTitle: String?
    public var transcriptPath: String?
    public var notificationMessage: String?

    // Token tracking
    public var totalInputTokens: Int
    public var totalOutputTokens: Int
    public var totalCacheCreationTokens: Int
    public var totalCacheReadTokens: Int

    /// User-facing title for the agent, preferring meaningful pane titles.
    public var displayTitle: String {
        let title: String? = paneTitle.flatMap { (paneTitle: String) -> String? in
            let trimmed = paneTitle.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            if Self.ignoredPaneTitles.contains(trimmed.lowercased()) { return nil }
            if !trimmed.contains(" "), trimmed.contains(".") { return nil }
            return trimmed
        }
        let raw = title ?? agentType.capitalized
        if raw.count > 2, raw.hasPrefix("_ ") {
            return String(raw.dropFirst(2))
        }
        return raw
    }

    public init(
        sessionId: String,
        name: String,
        avatarSeed: String,
        cwd: String,
        agentType: String = "claude",
        model: String? = nil,
        tmuxSession: String? = nil,
        host: String? = nil,
        startedAt: Date = Date(),
        lastActivityAt: Date = Date(),
        status: AgentStatus = .active,
        currentToolName: String? = nil,
        lastNotificationType: String? = nil,
        subagentCount: Int = 0,
        paneTitle: String? = nil,
        transcriptPath: String? = nil,
        notificationMessage: String? = nil,
        totalInputTokens: Int = 0,
        totalOutputTokens: Int = 0,
        totalCacheCreationTokens: Int = 0,
        totalCacheReadTokens: Int = 0
    ) {
        self.sessionId = sessionId
        self.name = name
        self.avatarSeed = avatarSeed
        self.cwd = cwd
        self.agentType = agentType
        self.model = model
        self.tmuxSession = tmuxSession
        self.host = host
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.status = status
        self.currentToolName = currentToolName
        self.lastNotificationType = lastNotificationType
        self.subagentCount = subagentCount
        self.paneTitle = paneTitle
        self.transcriptPath = transcriptPath
        self.notificationMessage = notificationMessage
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalCacheCreationTokens = totalCacheCreationTokens
        self.totalCacheReadTokens = totalCacheReadTokens
    }

    /// Titles that processes set automatically and aren't meaningful to display.
    private static let ignoredPaneTitles: Set<String> = [
        "node", "bash", "zsh", "sh", "fish", "python", "python3", "ruby",
        "bun", "deno", "npx", "tsx",
    ]
}
