import ArgumentParser
import Foundation
import WorkforceKit

struct MCPServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp-serve",
        abstract: "Run as an MCP (Model Context Protocol) server over stdio"
    )

    func run() throws {
        let server = MCPServer()
        server.run()
    }
}

// MARK: - MCP Server

private final class MCPServer {
    private let sessionId: String
    private let cwd: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        if let session = ProcessInfo.processInfo.environment["WORKFORCE_SESSION"] {
            self.sessionId = session
        } else {
            self.sessionId = "mcp-\(ProcessInfo.processInfo.processIdentifier)"
        }
        self.cwd = FileManager.default.currentDirectoryPath
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            handleMessage(line)
        }
    }

    private func handleMessage(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let id = json["id"]
        let method = json["method"] as? String ?? ""
        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            handleInitialize(id: id, params: params)
        case "notifications/initialized":
            break
        case "tools/list":
            handleToolsList(id: id)
        case "tools/call":
            handleToolsCall(id: id, params: params)
        case "ping":
            sendResult(id: id, result: [:])
        default:
            sendError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Initialize

    private func handleInitialize(id: Any?, params: [String: Any]) {
        let result: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": [
                    "listChanged": false
                ]
            ],
            "serverInfo": [
                "name": "workforce",
                "version": "0.3.0"
            ]
        ]
        sendResult(id: id, result: result)
    }

    // MARK: - Tools List

    private func handleToolsList(id: Any?) {
        let tools: [[String: Any]] = [
            [
                "name": "send_message",
                "description": "Send a message to another agent managed by Workforce. Messages are delivered to the target agent's file-based mailbox and the agent will be notified when it becomes idle.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "to": [
                            "type": "string",
                            "description": "Target agent session ID or partial match (e.g. 'workforce-1740268800' or '1740268800')"
                        ],
                        "message": [
                            "type": "string",
                            "description": "The message body to send"
                        ],
                        "subject": [
                            "type": "string",
                            "description": "Optional subject line for the message"
                        ],
                        "type": [
                            "type": "string",
                            "enum": ["message", "artifact", "status_update", "work_request"],
                            "description": "Type of message. Defaults to 'message'."
                        ],
                        "priority": [
                            "type": "string",
                            "enum": ["low", "normal", "high"],
                            "description": "Message priority. Defaults to 'normal'."
                        ]
                    ],
                    "required": ["to", "message"]
                ]
            ],
            [
                "name": "broadcast_message",
                "description": "Broadcast a message to all agents. Use scope 'project' to reach all agents working in the same directory (current and future), or 'global' to reach all agents everywhere. Broadcast messages persist and are visible to agents that start after the message was sent.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "message": [
                            "type": "string",
                            "description": "The message body to broadcast"
                        ],
                        "scope": [
                            "type": "string",
                            "enum": ["project", "global"],
                            "description": "Broadcast scope. 'project' sends to all agents in the same working directory. 'global' sends to all agents everywhere. Defaults to 'project'."
                        ],
                        "subject": [
                            "type": "string",
                            "description": "Optional subject line"
                        ],
                        "type": [
                            "type": "string",
                            "enum": ["message", "artifact", "status_update", "work_request", "instruction"],
                            "description": "Type of message. Defaults to 'message'."
                        ],
                        "priority": [
                            "type": "string",
                            "enum": ["low", "normal", "high"],
                            "description": "Message priority. Defaults to 'normal'."
                        ]
                    ],
                    "required": ["message"]
                ]
            ],
            [
                "name": "read_messages",
                "description": "Read messages from other agents in your inbox, including broadcast messages. Returns unread/unseen messages by default.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "all": [
                            "type": "boolean",
                            "description": "If true, return all messages including already-read ones. Default: false."
                        ],
                        "mark_read": [
                            "type": "boolean",
                            "description": "If true, mark returned messages as read. Default: true."
                        ]
                    ],
                    "required": [] as [String]
                ]
            ],
            [
                "name": "list_agents",
                "description": "List all active agent sessions managed by Workforce, including their status, working directory, and session IDs. Use this to discover other agents you can communicate with.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [String]
                ]
            ]
        ]

        sendResult(id: id, result: ["tools": tools])
    }

    // MARK: - Tools Call

    private func handleToolsCall(id: Any?, params: [String: Any]) {
        let toolName = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        switch toolName {
        case "send_message":
            handleSendMessage(id: id, arguments: arguments)
        case "broadcast_message":
            handleBroadcastMessage(id: id, arguments: arguments)
        case "read_messages":
            handleReadMessages(id: id, arguments: arguments)
        case "list_agents":
            handleListAgents(id: id, arguments: arguments)
        default:
            sendError(id: id, code: -32602, message: "Unknown tool: \(toolName)")
        }
    }

    // MARK: - send_message

    private func handleSendMessage(id: Any?, arguments: [String: Any]) {
        guard let to = arguments["to"] as? String,
              let message = arguments["message"] as? String else {
            sendError(id: id, code: -32602, message: "Missing required parameters: 'to' and 'message'")
            return
        }

        let subject = arguments["subject"] as? String
        let typeStr = arguments["type"] as? String ?? "message"
        let priorityStr = arguments["priority"] as? String ?? "normal"

        let toSession = resolveTarget(to)
        let msgType = AgentMessage.MessageType(rawValue: typeStr) ?? .message
        let msgPriority = AgentMessage.Priority(rawValue: priorityStr) ?? .normal

        let agentMessage = AgentMessage(
            from: sessionId,
            to: toSession,
            type: msgType,
            priority: msgPriority,
            subject: subject,
            body: message
        )

        do {
            try Mailbox.deliver(agentMessage)

            SocketClient.send(SocketMessage(
                type: .agentMessage,
                sessionId: sessionId,
                cwd: cwd,
                messageFrom: sessionId,
                messageTo: toSession,
                messageBody: message,
                messageSubject: subject,
                messageType: typeStr,
                messagePriority: priorityStr
            ))

            sendToolResult(id: id, text: "Message sent to \(toSession)")
        } catch {
            sendToolResult(id: id, text: "Failed to send message: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - broadcast_message

    private func handleBroadcastMessage(id: Any?, arguments: [String: Any]) {
        guard let message = arguments["message"] as? String else {
            sendError(id: id, code: -32602, message: "Missing required parameter: 'message'")
            return
        }

        let scope = arguments["scope"] as? String ?? "project"
        let subject = arguments["subject"] as? String
        let typeStr = arguments["type"] as? String ?? "message"
        let priorityStr = arguments["priority"] as? String ?? "normal"
        let msgType = AgentMessage.MessageType(rawValue: typeStr) ?? .message
        let msgPriority = AgentMessage.Priority(rawValue: priorityStr) ?? .normal

        let broadcastTo = scope == "global" ? "broadcast:global" : "broadcast:project"
        let agentMessage = AgentMessage(
            from: sessionId,
            to: broadcastTo,
            type: msgType,
            priority: msgPriority,
            subject: subject,
            body: message
        )

        do {
            if scope == "global" {
                try Mailbox.broadcastGlobal(agentMessage)
            } else {
                try Mailbox.broadcastToProject(cwd: cwd, agentMessage)
            }

            SocketClient.send(SocketMessage(
                type: .agentMessage,
                sessionId: sessionId,
                cwd: cwd,
                messageFrom: sessionId,
                messageTo: broadcastTo,
                messageBody: message,
                messageSubject: subject,
                messageType: typeStr,
                messagePriority: priorityStr
            ))

            let scopeLabel = scope == "global" ? "all agents globally" : "all agents in project"
            sendToolResult(id: id, text: "Message broadcast to \(scopeLabel). Current and future agents will see this message.")
        } catch {
            sendToolResult(id: id, text: "Failed to broadcast: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - read_messages

    private func handleReadMessages(id: Any?, arguments: [String: Any]) {
        let all = arguments["all"] as? Bool ?? false
        let markRead = arguments["mark_read"] as? Bool ?? true

        do {
            // Direct messages
            var messages = all
                ? try Mailbox.readInbox(for: sessionId)
                : try Mailbox.readUnread(for: sessionId)

            // Broadcast messages (unseen)
            let broadcasts = (try? Mailbox.readNewBroadcasts(for: sessionId, cwd: cwd)) ?? []
            messages.append(contentsOf: broadcasts)
            messages.sort { $0.timestamp < $1.timestamp }

            if messages.isEmpty {
                sendToolResult(id: id, text: all ? "No messages in inbox." : "No unread messages.")
                return
            }

            var output = ""
            for (index, msg) in messages.enumerated() {
                if index > 0 { output += "\n---\n" }
                let priorityTag = msg.priority == .high ? " [HIGH PRIORITY]" : ""
                let typeTag = msg.type != .message ? " [\(msg.type.rawValue)]" : ""
                let broadcastTag = msg.to.hasPrefix("broadcast:") ? " [broadcast]" : ""
                output += "From: \(msg.from)\(priorityTag)\(typeTag)\(broadcastTag)\n"
                output += "Time: \(ISO8601DateFormatter().string(from: msg.timestamp))\n"
                if let subject = msg.subject {
                    output += "Subject: \(subject)\n"
                }
                output += "\n\(msg.body)"
            }
            output += "\n\n\(messages.count) message\(messages.count == 1 ? "" : "s")"

            if markRead {
                try Mailbox.markAllAsRead(for: sessionId)
                Mailbox.markBroadcastsSeen(sessionId: sessionId, cwd: cwd)
            }

            sendToolResult(id: id, text: output)
        } catch {
            sendToolResult(id: id, text: "Failed to read messages: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - list_agents

    private func handleListAgents(id: Any?, arguments: [String: Any]) {
        let agents = APIClient.fetchAgents() ?? TmuxClient.discoverAgents()

        if agents.isEmpty {
            sendToolResult(id: id, text: "No active agent sessions.")
            return
        }

        var output = ""
        for agent in agents {
            let isSelf = agent.sessionId == sessionId ? " (you)" : ""
            output += "- \(agent.sessionId)\(isSelf)\n"
            output += "  Title: \(agent.displayTitle)\n"
            output += "  Status: \(agent.status.rawValue)\n"
            output += "  CWD: \(agent.cwd)\n"
            output += "  Agent: \(agent.agentType)\n"
            let unread = Mailbox.unreadCountWithBroadcasts(for: agent.sessionId, cwd: agent.cwd)
            if unread > 0 {
                output += "  Unread messages: \(unread)\n"
            }
            output += "\n"
        }
        output += "\(agents.count) agent\(agents.count == 1 ? "" : "s") total"

        sendToolResult(id: id, text: output)
    }

    // MARK: - Target Resolution

    private func resolveTarget(_ input: String) -> String {
        let agents = APIClient.fetchAgents() ?? TmuxClient.discoverAgents()

        if agents.contains(where: { $0.sessionId == input }) {
            return input
        }

        let partialMatches = agents.filter { $0.sessionId.contains(input) }
        if partialMatches.count == 1 {
            return partialMatches[0].sessionId
        }

        let titleMatches = agents.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(input)
        }
        if titleMatches.count == 1 {
            return titleMatches[0].sessionId
        }

        return input
    }

    // MARK: - JSON-RPC Response Helpers

    private func sendResult(id: Any?, result: [String: Any]) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id = id {
            response["id"] = id
        }
        writeJSON(response)
    }

    private func sendToolResult(id: Any?, text: String, isError: Bool = false) {
        let content: [[String: Any]] = [
            ["type": "text", "text": text]
        ]
        var result: [String: Any] = ["content": content]
        if isError {
            result["isError"] = true
        }
        sendResult(id: id, result: result)
    }

    private func sendError(id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message
            ] as [String: Any]
        ]
        if let id = id {
            response["id"] = id
        }
        writeJSON(response)
    }

    private func writeJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              var json = String(data: data, encoding: .utf8) else { return }
        json += "\n"
        FileHandle.standardOutput.write(Data(json.utf8))
    }
}
