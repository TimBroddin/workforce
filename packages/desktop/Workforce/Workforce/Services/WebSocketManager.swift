import Foundation
import Network
import CommonCrypto

// MARK: - WebSocket message envelope

struct WebSocketMessage: Encodable {
    let kind: String        // "event" or "snapshot"
    let event: SocketMessage?
    let agents: [Agent]?
}

// MARK: - WebSocket Manager

final class WebSocketManager {
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var pingTimers: [ObjectIdentifier: DispatchSourceTimer] = [:]
    private let store: AgentStore
    private let encoder: JSONEncoder

    init(store: AgentStore) {
        self.store = store
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    // MARK: - Connection upgrade

    /// Perform WebSocket handshake and start the frame read loop.
    /// The caller must NOT cancel the NWConnection after calling this.
    func upgradeConnection(_ connection: NWConnection, secWebSocketKey: String) {
        let acceptKey = computeAcceptKey(secWebSocketKey)
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(acceptKey)",
            "",
            "",
        ].joined(separator: "\r\n")

        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            let id = ObjectIdentifier(connection)
            self.connections[id] = connection
            self.startPingTimer(for: connection)
            self.sendSnapshot(to: connection)
            self.readFrame(on: connection)
        })
    }

    // MARK: - Broadcast

    func broadcast(_ message: SocketMessage) {
        let envelope = WebSocketMessage(kind: "event", event: message, agents: nil)
        guard let data = try? encoder.encode(envelope) else { return }
        let frame = writeTextFrame(data)
        for (_, conn) in connections {
            conn.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Snapshot

    private func sendSnapshot(to connection: NWConnection) {
        let envelope = WebSocketMessage(kind: "snapshot", event: nil, agents: store.sortedAgents)
        guard let data = try? encoder.encode(envelope) else { return }
        let frame = writeTextFrame(data)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    // MARK: - Frame read loop

    private func readFrame(on connection: NWConnection) {
        // Read at least 2 bytes (minimum WS frame header)
        connection.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil || content == nil {
                self.removeConnection(connection)
                return
            }

            guard let data = content else {
                self.readFrame(on: connection)
                return
            }

            self.processFrame(data, on: connection)
        }
    }

    private func processFrame(_ data: Data, on connection: NWConnection) {
        guard data.count >= 2 else {
            readFrame(on: connection)
            return
        }

        let byte0 = data[data.startIndex]
        let byte1 = data[data.startIndex + 1]
        let opcode = byte0 & 0x0F
        let masked = (byte1 & 0x80) != 0
        var payloadLen = UInt64(byte1 & 0x7F)
        var offset = 2

        if payloadLen == 126 {
            guard data.count >= 4 else { readFrame(on: connection); return }
            payloadLen = UInt64(data[data.startIndex + 2]) << 8 | UInt64(data[data.startIndex + 3])
            offset = 4
        } else if payloadLen == 127 {
            guard data.count >= 10 else { readFrame(on: connection); return }
            payloadLen = 0
            for i in 0..<8 {
                payloadLen = (payloadLen << 8) | UInt64(data[data.startIndex + 2 + i])
            }
            offset = 10
        }

        var maskKey: [UInt8] = []
        if masked {
            guard data.count >= offset + 4 else { readFrame(on: connection); return }
            maskKey = Array(data[(data.startIndex + offset)..<(data.startIndex + offset + 4)])
            offset += 4
        }

        let totalNeeded = offset + Int(payloadLen)
        if data.count < totalNeeded {
            // Need more data — accumulate and re-read
            readFrame(on: connection)
            return
        }

        var payload = Array(data[(data.startIndex + offset)..<(data.startIndex + totalNeeded)])
        if masked {
            for i in 0..<payload.count {
                payload[i] ^= maskKey[i % 4]
            }
        }

        switch opcode {
        case 0x1: // text frame
            handleTextMessage(Data(payload), on: connection)
        case 0x8: // close
            sendCloseFrame(on: connection)
            removeConnection(connection)
            return
        case 0x9: // ping — reply with pong
            let pong = writePongFrame(Data(payload))
            connection.send(content: pong, completion: .contentProcessed { _ in })
        case 0xA: // pong — ignore
            break
        default:
            break
        }

        readFrame(on: connection)
    }

    private func handleTextMessage(_ data: Data, on connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else { return }

        if action == "snapshot" {
            sendSnapshot(to: connection)
        }
    }

    // MARK: - Connection management

    private func removeConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections.removeValue(forKey: id)
        pingTimers[id]?.cancel()
        pingTimers.removeValue(forKey: id)
        connection.cancel()
    }

    func removeAllConnections() {
        for (_, conn) in connections {
            sendCloseFrame(on: conn)
            conn.cancel()
        }
        connections.removeAll()
        for (_, timer) in pingTimers { timer.cancel() }
        pingTimers.removeAll()
    }

    var connectionCount: Int { connections.count }

    // MARK: - Ping timer (keeps SSH tunnels alive)

    private func startPingTimer(for connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self, self.connections[id] != nil else {
                timer.cancel()
                return
            }
            let ping = self.writePingFrame()
            connection.send(content: ping, completion: .contentProcessed { _ in })
        }
        timer.resume()
        pingTimers[id] = timer
    }

    // MARK: - Frame writing (server → client, unmasked)

    private func writeTextFrame(_ payload: Data) -> Data {
        return writeFrame(opcode: 0x1, payload: payload)
    }

    private func writePingFrame() -> Data {
        return writeFrame(opcode: 0x9, payload: Data())
    }

    private func writePongFrame(_ payload: Data) -> Data {
        return writeFrame(opcode: 0xA, payload: payload)
    }

    private func sendCloseFrame(on connection: NWConnection) {
        let frame = writeFrame(opcode: 0x8, payload: Data())
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func writeFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode) // FIN + opcode

        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 65535 {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for i in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((payload.count >> i) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }

    // MARK: - WebSocket accept key (RFC 6455 §4.2.2)

    private func computeAcceptKey(_ clientKey: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = clientKey + magic
        let data = Data(combined.utf8)

        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash).base64EncodedString()
    }
}
