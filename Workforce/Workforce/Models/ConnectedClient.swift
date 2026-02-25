import Foundation

struct ConnectedClient: Codable, Identifiable {
    let clientId: String
    let hostname: String
    let user: String
    var lastSeen: Date

    var id: String { clientId }

    var displayName: String {
        "\(user)@\(hostname)"
    }
}
