import SwiftUI

struct AgentRowView: View {
    let agent: Agent

    var body: some View {
        HStack(spacing: 8) {
            Text(displayName)
                .font(.system(.body, design: .default))
                .lineLimit(1)

            if agent.agentType != "claude" {
                Text(agent.agentType)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            if agent.subagentCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "cpu")
                        .font(.caption2)
                    Text("\(agent.subagentCount)")
                        .font(.caption2)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            Spacer()

            PulsingDot(color: statusColor, isPulsing: agent.status == .active)
                .help(statusLabel)
        }
        .padding(.vertical, 6)
        .padding(.leading, 28)
        .padding(.trailing, 12)
    }

    /// Titles that processes set automatically and aren't meaningful to display.
    private static let ignoredPaneTitles: Set<String> = [
        "node", "bash", "zsh", "sh", "fish", "python", "python3", "ruby",
        "bun", "deno", "npx", "tsx",
    ]

    private var displayName: String {
        let title: String? = agent.paneTitle.flatMap { title in
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            if Self.ignoredPaneTitles.contains(trimmed.lowercased()) { return nil }
            // Ignore hostname-like titles (no spaces, contains a dot or matches common patterns)
            if !trimmed.contains(" "), trimmed.contains(".") { return nil }
            return trimmed
        }
        let raw = title ?? agent.agentType.capitalized
        if raw.count > 2, raw.hasPrefix("_ ") {
            return String(raw.dropFirst(2))
        }
        return raw
    }

    private var statusLabel: String {
        switch agent.status {
        case .active: "Working"
        case .waitingForInput: "Waiting for input"
        case .waitingForPermission: "Waiting for permission"
        case .idle: "Idle"
        case .stopped: "Stopped"
        }
    }

    private var statusColor: Color {
        switch agent.status {
        case .active: .green
        case .waitingForInput: .blue
        case .waitingForPermission: .blue
        case .idle: .green
        case .stopped: .gray.opacity(0.5)
        }
    }
}

private struct PulsingDot: View {
    let color: Color
    let isPulsing: Bool

    @State private var animating = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(animating ? 0.3 : 1.0)
            .onChange(of: isPulsing, initial: true) { _, pulse in
                if pulse {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        animating = true
                    }
                } else {
                    withAnimation(.default) {
                        animating = false
                    }
                }
            }
    }
}
