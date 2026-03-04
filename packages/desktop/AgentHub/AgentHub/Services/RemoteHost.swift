import Foundation

enum ConnectionStatus: Equatable {
    case disabled
    case connecting
    case connected
    case error(String)

    var label: String {
        switch self {
        case .disabled: "Disabled"
        case .connecting: "Connecting..."
        case .connected: "Connected"
        case .error(let msg): "Error: \(msg)"
        }
    }
}

struct RemoteHost: Codable, Identifiable {
    let id: UUID
    var label: String
    var sshDestination: String
    var sshPort: Int
    var sshKeyPath: String?
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        label: String,
        sshDestination: String,
        sshPort: Int = 22,
        sshKeyPath: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.label = label
        self.sshDestination = sshDestination
        self.sshPort = sshPort
        self.sshKeyPath = sshKeyPath
        self.isEnabled = isEnabled
    }

    /// Build the base SSH command arguments for this host.
    var sshBaseArgs: [String] {
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        if sshPort != 22 {
            args += ["-p", "\(sshPort)"]
        }
        if let key = sshKeyPath {
            args += ["-i", (key as NSString).expandingTildeInPath]
        }
        args.append(sshDestination)
        return args
    }
}
