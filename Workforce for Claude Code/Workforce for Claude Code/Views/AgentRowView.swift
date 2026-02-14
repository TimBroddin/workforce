import SwiftUI

struct AgentRowView: View {
    let agent: Agent
    var onFocus: () -> Void

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

            Button("Focus", action: onFocus)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
