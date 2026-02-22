import SwiftUI

struct AgentRowView: View {
    let agent: Agent
    @AppStorage("showCosts") private var showCosts = true

    var body: some View {
        HStack(spacing: 8) {
            Text(agent.displayTitle)
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

            if showCosts, agent.totalInputTokens > 0 || agent.totalOutputTokens > 0 {
                let cost = CostCalculator.estimateCost(
                    model: agent.model,
                    inputTokens: agent.totalInputTokens,
                    outputTokens: agent.totalOutputTokens,
                    cacheCreationTokens: agent.totalCacheCreationTokens,
                    cacheReadTokens: agent.totalCacheReadTokens
                )
                Text(CostCalculator.formatCost(cost))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            PulsingDot(color: statusColor, isPulsing: agent.status == .active)
                .help(statusLabel)
        }
        .padding(.vertical, 6)
        .padding(.leading, 28)
        .padding(.trailing, 12)
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
