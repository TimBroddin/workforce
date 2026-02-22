import Foundation
import Network

final class SocketServer {
    private var listener: NWListener?
    private let store: AgentStore
    private let eventLog: EventLog
    private let messageStore: MessageStore
    private let socketPath: String

    init(store: AgentStore, eventLog: EventLog, messageStore: MessageStore) {
        self.store = store
        self.eventLog = eventLog
        self.messageStore = messageStore
        self.socketPath = "/tmp/workforce-\(getuid()).sock"
    }

    func start() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: socketPath) {
            try fm.removeItem(atPath: socketPath)
        }

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        listener = try NWListener(using: params)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveData(on: connection, accumulated: Data())
    }

    private func receiveData(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }

            var buffer = accumulated
            if let content { buffer.append(content) }

            if isComplete || error != nil {
                if !buffer.isEmpty {
                    self.processMessage(buffer)
                }
                connection.cancel()
            } else {
                self.receiveData(on: connection, accumulated: buffer)
            }
        }
    }

    private func processMessage(_ data: Data) {
        let lines = data.split(separator: UInt8(ascii: "\n"))
        for line in lines {
            let raw = String(data: Data(line), encoding: .utf8) ?? "<invalid utf8>"
            NSLog("[Workforce] Received: %@", raw)
            do {
                let message = try JSONDecoder().decode(SocketMessage.self, from: Data(line))
                NSLog("[Workforce] Decoded: type=%@ session=%@ tmux=%@",
                      message.type.rawValue, message.sessionId, message.tmuxSession ?? "nil")
                eventLog.append(message: message, rawJSON: raw)
                store.handleMessage(message)
                if message.type == .agentMessage {
                    messageStore.recordMessage(from: message)
                }
            } catch {
                NSLog("[Workforce] Decode error: %@", error.localizedDescription)
                eventLog.append(message: nil, rawJSON: raw, error: error.localizedDescription)
            }
        }
    }
}
