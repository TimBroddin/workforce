import Foundation
import Observation

@Observable
final class MessageStore {
    private(set) var messages: [AgentMessage] = []
    private let maxMessages = 500

    /// Record a new inter-agent message received via socket notification.
    func recordMessage(from socketMessage: SocketMessage) {
        guard let from = socketMessage.messageFrom,
              let to = socketMessage.messageTo,
              let body = socketMessage.messageBody else { return }

        let message = AgentMessage(
            id: UUID().uuidString,
            from: from,
            to: to,
            timestamp: socketMessage.timestamp,
            type: AgentMessage.MessageType(rawValue: socketMessage.messageType ?? "message") ?? .message,
            priority: AgentMessage.Priority(rawValue: socketMessage.messagePriority ?? "normal") ?? .normal,
            subject: socketMessage.messageSubject,
            body: body,
            status: .unread
        )

        messages.append(message)

        // Trim old messages
        if messages.count > maxMessages {
            messages.removeFirst(messages.count - maxMessages)
        }
    }

    /// All messages involving agents in a specific cwd.
    func messages(forAgents agentIds: Set<String>) -> [AgentMessage] {
        messages.filter { agentIds.contains($0.from) || agentIds.contains($0.to) }
    }

    /// Messages sent to a specific agent.
    func messagesTo(_ sessionId: String) -> [AgentMessage] {
        messages.filter { $0.to == sessionId }
    }

    /// Messages sent from a specific agent.
    func messagesFrom(_ sessionId: String) -> [AgentMessage] {
        messages.filter { $0.from == sessionId }
    }

    /// All messages involving a specific agent (sent or received).
    func messagesFor(_ sessionId: String) -> [AgentMessage] {
        messages.filter { $0.from == sessionId || $0.to == sessionId }
    }

    func clear() {
        messages.removeAll()
    }
}
