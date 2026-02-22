import Foundation

/// A message exchanged between agents via the file-based mailbox system.
/// (App-local copy, mirroring WorkforceKit's AgentMessage.)
struct AgentMessage: Codable, Identifiable, Sendable {
    let id: String
    let from: String
    let to: String
    let timestamp: Date
    let type: MessageType
    let priority: Priority
    let subject: String?
    let body: String
    var status: ReadStatus

    enum MessageType: String, Codable, Sendable {
        case message
        case instruction
        case workRequest = "work_request"
        case artifact
        case statusUpdate = "status_update"
    }

    enum Priority: String, Codable, Sendable {
        case low
        case normal
        case high
    }

    enum ReadStatus: String, Codable, Sendable {
        case unread
        case read
    }
}
