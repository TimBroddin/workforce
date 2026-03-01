import Foundation
import Observation

@Observable
final class ClientRegistry {
    private(set) var clients: [String: ConnectedClient] = [:]
    private var pruneTimer: Timer?
    private let staleThreshold: TimeInterval = 90

    var connectedClients: [ConnectedClient] {
        Array(clients.values).sorted { $0.hostname < $1.hostname }
    }

    func register(clientId: String, hostname: String, user: String) {
        clients[clientId] = ConnectedClient(
            clientId: clientId,
            hostname: hostname,
            user: user,
            lastSeen: Date()
        )
    }

    func startPruning() {
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.pruneStaleClients()
        }
    }

    func stopPruning() {
        pruneTimer?.invalidate()
        pruneTimer = nil
    }

    private func pruneStaleClients() {
        let cutoff = Date().addingTimeInterval(-staleThreshold)
        clients = clients.filter { $0.value.lastSeen > cutoff }
    }
}
