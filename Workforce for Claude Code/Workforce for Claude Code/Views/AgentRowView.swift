import SwiftUI

struct AgentRowView: View {
    let agent: Agent

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(seed: agent.avatarSeed)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(agent.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    StatusBadge(status: agent.status)
                }

                Text(abbreviatePath(agent.cwd))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(agent.hostApp.rawValue.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let model = agent.model {
                        Text("\u{00B7}").foregroundStyle(.tertiary)
                        Text(formatModel(model))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if let tool = agent.currentToolName {
                        Text("\u{00B7}").foregroundStyle(.tertiary)
                        Text("using \(tool)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if agent.subagentCount > 0 {
                        Text("\u{00B7}").foregroundStyle(.tertiary)
                        Text("\(agent.subagentCount) subagent\(agent.subagentCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    private func formatModel(_ model: String) -> String {
        let lowered = model.lowercased()
        if lowered.contains("opus") { return "Opus" }
        if lowered.contains("sonnet") { return "Sonnet" }
        if lowered.contains("haiku") { return "Haiku" }
        return model
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
