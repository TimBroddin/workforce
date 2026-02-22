import Foundation

/// File-based mailbox system for inter-agent communication.
///
/// Layout:
/// ```
/// ~/.workforce/mailboxes/
///   <session-id>/
///     inbox/
///       <message-id>.json
///     seen/
///       <channel-hash>.timestamp     # tracks last-seen time per broadcast channel
///   broadcast/
///     global/
///       <message-id>.json
///     project/
///       <cwd-hash>/
///         <message-id>.json
/// ```
public enum Mailbox {
    private static let baseDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".workforce/mailboxes", isDirectory: true)
    }()

    private static let fm = FileManager.default

    // MARK: - Direct Messages

    private static func inboxDir(for sessionId: String) -> URL {
        baseDir.appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("inbox", isDirectory: true)
    }

    /// Write a message to the target agent's inbox.
    public static func deliver(_ message: AgentMessage) throws {
        let dir = inboxDir(for: message.to)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeMessage(message, to: dir)
    }

    /// Read all messages in an agent's inbox, sorted by timestamp (oldest first).
    public static func readInbox(for sessionId: String) throws -> [AgentMessage] {
        let dir = inboxDir(for: sessionId)
        return try readMessages(from: dir)
    }

    /// Read only unread messages in an agent's inbox.
    public static func readUnread(for sessionId: String) throws -> [AgentMessage] {
        try readInbox(for: sessionId).filter { $0.status == .unread }
    }

    /// Count unread messages for an agent (direct only — use unreadCountWithBroadcasts for full count).
    public static func unreadCount(for sessionId: String) -> Int {
        (try? readUnread(for: sessionId).count) ?? 0
    }

    /// Mark a message as read by rewriting it with updated status.
    public static func markAsRead(sessionId: String, messageId: String) throws {
        let file = inboxDir(for: sessionId).appendingPathComponent("\(messageId).json")
        guard fm.fileExists(atPath: file.path) else { return }
        try markMessageAsRead(at: file)
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

    /// Clean up the mailbox for a deregistered agent.
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
            let name = url.lastPathComponent
            // Skip the broadcast directory
            guard name != "broadcast" else { return nil }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            return name
        }
    }

    // MARK: - Broadcast Messages

    private static var broadcastDir: URL {
        baseDir.appendingPathComponent("broadcast", isDirectory: true)
    }

    private static var globalBroadcastDir: URL {
        broadcastDir.appendingPathComponent("global", isDirectory: true)
    }

    private static func projectBroadcastDir(cwd: String) -> URL {
        let hash = cwdHash(cwd)
        return broadcastDir
            .appendingPathComponent("project", isDirectory: true)
            .appendingPathComponent(hash, isDirectory: true)
    }

    /// Broadcast a message to all agents globally.
    public static func broadcastGlobal(_ message: AgentMessage) throws {
        let dir = globalBroadcastDir
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeMessage(message, to: dir)
    }

    /// Broadcast a message to all agents in a specific project (cwd).
    public static func broadcastToProject(cwd: String, _ message: AgentMessage) throws {
        let dir = projectBroadcastDir(cwd: cwd)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Also write a .cwd marker file so readers can display the project path
        let markerFile = dir.appendingPathComponent(".cwd")
        if !fm.fileExists(atPath: markerFile.path) {
            try cwd.write(to: markerFile, atomically: true, encoding: .utf8)
        }

        try writeMessage(message, to: dir)
    }

    /// Read broadcast messages that an agent hasn't seen yet.
    /// Returns unseen global + project broadcasts for this agent's cwd.
    public static func readNewBroadcasts(for sessionId: String, cwd: String) throws -> [AgentMessage] {
        var results: [AgentMessage] = []

        // Global broadcasts
        let globalSeen = lastSeenTimestamp(sessionId: sessionId, channel: "global")
        let globalMessages = try readMessages(from: globalBroadcastDir)
            .filter { $0.from != sessionId && $0.timestamp > globalSeen }
        results.append(contentsOf: globalMessages)

        // Project broadcasts
        let channelKey = "project-\(cwdHash(cwd))"
        let projectSeen = lastSeenTimestamp(sessionId: sessionId, channel: channelKey)
        let projectDir = projectBroadcastDir(cwd: cwd)
        let projectMessages = try readMessages(from: projectDir)
            .filter { $0.from != sessionId && $0.timestamp > projectSeen }
        results.append(contentsOf: projectMessages)

        return results.sorted { $0.timestamp < $1.timestamp }
    }

    /// Mark broadcast channels as seen up to now for this agent.
    public static func markBroadcastsSeen(sessionId: String, cwd: String) {
        let now = Date()
        setLastSeenTimestamp(sessionId: sessionId, channel: "global", date: now)
        let channelKey = "project-\(cwdHash(cwd))"
        setLastSeenTimestamp(sessionId: sessionId, channel: channelKey, date: now)
    }

    /// Count of unseen broadcasts for an agent.
    public static func unseenBroadcastCount(for sessionId: String, cwd: String) -> Int {
        (try? readNewBroadcasts(for: sessionId, cwd: cwd).count) ?? 0
    }

    /// Total unread: direct messages + unseen broadcasts.
    public static func unreadCountWithBroadcasts(for sessionId: String, cwd: String) -> Int {
        unreadCount(for: sessionId) + unseenBroadcastCount(for: sessionId, cwd: cwd)
    }

    // MARK: - Seen Tracking

    private static func seenDir(for sessionId: String) -> URL {
        baseDir.appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("seen", isDirectory: true)
    }

    private static func lastSeenTimestamp(sessionId: String, channel: String) -> Date {
        let file = seenDir(for: sessionId).appendingPathComponent("\(channel).timestamp")
        guard let data = try? String(contentsOf: file, encoding: .utf8),
              let interval = TimeInterval(data.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return Date.distantPast
        }
        return Date(timeIntervalSince1970: interval)
    }

    private static func setLastSeenTimestamp(sessionId: String, channel: String, date: Date) {
        let dir = seenDir(for: sessionId)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(channel).timestamp")
        let value = String(date.timeIntervalSince1970)
        try? value.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private static func writeMessage(_ message: AgentMessage, to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(message)
        let file = dir.appendingPathComponent("\(message.id).json")
        try data.write(to: file, options: .atomic)
    }

    private static func readMessages(from dir: URL) throws -> [AgentMessage] {
        guard fm.fileExists(atPath: dir.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        var messages: [AgentMessage] = []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let message = try? decoder.decode(AgentMessage.self, from: data) else { continue }
            messages.append(message)
        }

        return messages.sorted { $0.timestamp < $1.timestamp }
    }

    private static func markMessageAsRead(at file: URL) throws {
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

    /// Stable hash of a cwd path for use as a directory name.
    private static func cwdHash(_ cwd: String) -> String {
        // Simple stable hash — take the path, replace slashes, truncate
        let clean = cwd.replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if clean.count <= 60 { return clean }
        // For long paths, use last component + a hash suffix
        let last = URL(fileURLWithPath: cwd).lastPathComponent
        var hash: UInt64 = 5381
        for byte in cwd.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return "\(last)-\(String(hash, radix: 16))"
    }
}
