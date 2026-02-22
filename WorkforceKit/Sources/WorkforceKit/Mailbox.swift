import Foundation

/// File-based mailbox system for inter-agent communication.
///
/// Layout:
/// ```
/// ~/.workforce/mailboxes/
///   <session-id>/
///     inbox/
///       <message-id>.json
/// ```
public enum Mailbox {
    private static let baseDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".workforce/mailboxes", isDirectory: true)
    }()

    private static let fm = FileManager.default

    private static func inboxDir(for sessionId: String) -> URL {
        baseDir.appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("inbox", isDirectory: true)
    }

    /// Write a message to the target agent's inbox.
    public static func deliver(_ message: AgentMessage) throws {
        let dir = inboxDir(for: message.to)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(message)

        let file = dir.appendingPathComponent("\(message.id).json")
        try data.write(to: file, options: .atomic)
    }

    /// Read all messages in an agent's inbox, sorted by timestamp (oldest first).
    public static func readInbox(for sessionId: String) throws -> [AgentMessage] {
        let dir = inboxDir(for: sessionId)
        guard fm.fileExists(atPath: dir.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        var messages: [AgentMessage] = []
        for file in files {
            let data = try Data(contentsOf: file)
            let message = try decoder.decode(AgentMessage.self, from: data)
            messages.append(message)
        }

        return messages.sorted { $0.timestamp < $1.timestamp }
    }

    /// Read only unread messages in an agent's inbox.
    public static func readUnread(for sessionId: String) throws -> [AgentMessage] {
        try readInbox(for: sessionId).filter { $0.status == .unread }
    }

    /// Count unread messages for an agent.
    public static func unreadCount(for sessionId: String) -> Int {
        (try? readUnread(for: sessionId).count) ?? 0
    }

    /// Mark a message as read by rewriting it with updated status.
    public static func markAsRead(sessionId: String, messageId: String) throws {
        let file = inboxDir(for: sessionId).appendingPathComponent("\(messageId).json")
        guard fm.fileExists(atPath: file.path) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: file)
        var message = try decoder.decode(AgentMessage.self, from: data)
        message.status = .read

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(message).write(to: file, options: .atomic)
    }

    /// Mark all messages in an agent's inbox as read.
    public static func markAllAsRead(for sessionId: String) throws {
        let messages = try readUnread(for: sessionId)
        for message in messages {
            try markAsRead(sessionId: sessionId, messageId: message.id)
        }
    }

    /// Delete a specific message from an agent's inbox.
    public static func delete(sessionId: String, messageId: String) throws {
        let file = inboxDir(for: sessionId).appendingPathComponent("\(messageId).json")
        if fm.fileExists(atPath: file.path) {
            try fm.removeItem(at: file)
        }
    }

    /// Clean up the mailbox for a deregistered agent (removes the entire mailbox directory).
    public static func cleanup(for sessionId: String) throws {
        let dir = baseDir.appendingPathComponent(sessionId, isDirectory: true)
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
    }

    /// List all session IDs that have mailbox directories.
    public static func allMailboxSessionIds() -> [String] {
        guard let contents = try? fm.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return contents.compactMap { url in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            return url.lastPathComponent
        }
    }
}
