import ArgumentParser
import Foundation
import WorkforceKit

struct InboxCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inbox",
        abstract: "Read messages from other agents (direct + broadcasts)"
    )

    @Flag(name: .long, help: "Show all messages (including read)")
    var all: Bool = false

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    @Flag(name: .long, help: "Mark all messages as read after displaying")
    var markRead: Bool = false

    @Flag(name: .long, help: "Only show direct messages (skip broadcasts)")
    var directOnly: Bool = false

    @Option(name: .long, help: "Session ID to check inbox for (defaults to current session)")
    var session: String?

    func run() throws {
        let sessionId = session ?? resolveCurrentSession()
        let cwd = FileManager.default.currentDirectoryPath

        // Direct messages
        var messages = all
            ? try Mailbox.readInbox(for: sessionId)
            : try Mailbox.readUnread(for: sessionId)

        // Broadcast messages (unseen)
        if !directOnly {
            let broadcasts = (try? Mailbox.readNewBroadcasts(for: sessionId, cwd: cwd)) ?? []
            messages.append(contentsOf: broadcasts)
        }

        // Sort combined by timestamp
        messages.sort { $0.timestamp < $1.timestamp }

        if messages.isEmpty {
            if !json {
                print(all ? "No messages." : "No unread messages.")
            } else {
                print("[]")
            }
            return
        }

        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(messages)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            printMessages(messages)
        }

        if markRead {
            try Mailbox.markAllAsRead(for: sessionId)
            Mailbox.markBroadcastsSeen(sessionId: sessionId, cwd: cwd)
        }
    }

    private func printMessages(_ messages: [AgentMessage]) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .none
        dateFormatter.timeStyle = .medium

        for (index, msg) in messages.enumerated() {
            if index > 0 { print("---") }

            let priorityTag = msg.priority == .high ? " [HIGH]" : (msg.priority == .low ? " [low]" : "")
            let statusTag = msg.status == .unread ? " (unread)" : ""
            let typeTag = msg.type != .message ? " [\(msg.type.rawValue)]" : ""
            let broadcastTag = msg.to.hasPrefix("broadcast:") ? " [broadcast]" : ""

            print("From: \(msg.from)\(priorityTag)\(typeTag)\(broadcastTag)\(statusTag)")
            print("Time: \(dateFormatter.string(from: msg.timestamp))")
            if let subject = msg.subject {
                print("Subject: \(subject)")
            }
            print("")
            print(msg.body)
        }

        print("")
        print("\(messages.count) message\(messages.count == 1 ? "" : "s")")
    }

    private func resolveCurrentSession() -> String {
        if let session = ProcessInfo.processInfo.environment["WORKFORCE_SESSION"] {
            return session
        }
        if let tmuxSession = detectCurrentTmuxSession(), tmuxSession.hasPrefix("workforce-") {
            return tmuxSession
        }
        fputs("Warning: Could not determine session ID. Use --session to specify.\n", stderr)
        return "unknown"
    }

    private func detectCurrentTmuxSession() -> String? {
        guard ProcessInfo.processInfo.environment["TMUX"] != nil else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "display-message", "-p", "#S"]
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let session = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let session, !session.isEmpty else { return nil }
            return session
        } catch { return nil }
    }
}
