import SwiftUI

struct StatusBadge: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch status {
        case .active: .green
        case .waitingForInput: .orange
        case .waitingForPermission: .red
        case .idle: .gray
        case .stopped: .gray.opacity(0.5)
        case .orphaned: .yellow
        }
    }

    private var label: String {
        switch status {
        case .active: "Active"
        case .waitingForInput: "Waiting for input"
        case .waitingForPermission: "Needs permission"
        case .idle: "Idle"
        case .stopped: "Stopped"
        case .orphaned: "Orphaned"
        }
    }
}
