import Foundation

/// A message exchanged between agents via the file-based mailbox system.
public struct AgentMessage: Codable, Identifiable, Sendable {
    public let id: String
    public let from: String
    public let to: String
    public let timestamp: Date
    public let type: MessageType
    public let priority: Priority
    public let subject: String?
    public let body: String
    public var status: ReadStatus

    public enum MessageType: String, Codable, Sendable {
        case message
        case instruction
        case workRequest = "work_request"
        case artifact
        case statusUpdate = "status_update"
    }

    public enum Priority: String, Codable, Sendable {
        case low
        case normal
        case high
    }

    public enum ReadStatus: String, Codable, Sendable {
        case unread
        case read
    }

    public init(
        id: String = UUID().uuidString,
        from: String,
        to: String,
        timestamp: Date = Date(),
        type: MessageType = .message,
        priority: Priority = .normal,
        subject: String? = nil,
        body: String,
        status: ReadStatus = .unread
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.timestamp = timestamp
        self.type = type
        self.priority = priority
        self.subject = subject
        self.body = body
        self.status = status
    }
}
