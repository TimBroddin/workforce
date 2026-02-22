import SwiftUI

struct ProjectDetailView: View {
    let cwd: String
    let store: AgentStore
    let eventLog: EventLog
    @State private var selectedTab = 0
    @State private var gitInfo: GitInfo?

    private var projectAgents: [Agent] {
        store.sortedAgents.filter { $0.cwd == cwd }
    }

    private var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                Text(projectName)
                    .font(.headline)
                Spacer()
                Text("\(projectAgents.count) agent\(projectAgents.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Tab picker
            Picker("", selection: $selectedTab) {
                Text("Stats").tag(0)
                Text("Git").tag(1)
                Text("Activity").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Tab content
            switch selectedTab {
            case 0:
                statsTab
            case 1:
                gitTab
            case 2:
                activityTab
            default:
                EmptyView()
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await refreshGitInfo()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await refreshGitInfo()
            }
        }
    }

    // MARK: - Stats Tab

    private var statsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let totalInput = projectAgents.reduce(0) { $0 + $1.totalInputTokens }
                let totalOutput = projectAgents.reduce(0) { $0 + $1.totalOutputTokens }
                let totalCost = projectAgents.reduce(0.0) { total, agent in
                    total + CostCalculator.estimateCost(
                        model: agent.model,
                        inputTokens: agent.totalInputTokens,
                        outputTokens: agent.totalOutputTokens,
                        cacheCreationTokens: agent.totalCacheCreationTokens,
                        cacheReadTokens: agent.totalCacheReadTokens
                    )
                }

                HStack(spacing: 16) {
                    StatCard(title: "Total Tokens", value: CostCalculator.formatTokens(totalInput + totalOutput))
                    StatCard(title: "Estimated Cost", value: CostCalculator.formatCost(totalCost))
                    StatCard(title: "Active", value: "\(projectAgents.filter { $0.status == .active }.count)")
                }

                if !projectAgents.isEmpty {
                    Text("Per Agent")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(projectAgents) { agent in
                        HStack {
                            Text(agent.displayTitle)
                                .font(.body)
                            if let model = agent.model {
                                Text(model)
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.quaternary)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                            Spacer()
                            let tokens = agent.totalInputTokens + agent.totalOutputTokens
                            if tokens > 0 {
                                Text(CostCalculator.formatTokens(tokens))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                let cost = CostCalculator.estimateCost(
                                    model: agent.model,
                                    inputTokens: agent.totalInputTokens,
                                    outputTokens: agent.totalOutputTokens,
                                    cacheCreationTokens: agent.totalCacheCreationTokens,
                                    cacheReadTokens: agent.totalCacheReadTokens
                                )
                                Text(CostCalculator.formatCost(cost))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Git Tab

    private var gitTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let info = gitInfo {
                    HStack {
                        Label(info.branch, systemImage: "arrow.triangle.branch")
                            .font(.body.weight(.medium))
                        Spacer()
                        if info.dirtyFileCount > 0 {
                            Text("\(info.dirtyFileCount) uncommitted")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    if !info.recentCommits.isEmpty {
                        Text("Recent Commits")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(info.recentCommits) { commit in
                            HStack(alignment: .top, spacing: 8) {
                                Text(commit.id)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(commit.message)
                                    .font(.caption)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } else {
                    Text("Not a git repository")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    // MARK: - Activity Tab

    private var activityTab: some View {
        let projectEntries = Array(
            eventLog.entries
                .reversed()
                .filter { $0.message?.cwd == cwd }
                .prefix(100)
        )

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if projectEntries.isEmpty {
                    Text("No recent activity")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(projectEntries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            if let message = entry.message {
                                Circle()
                                    .fill(message.type.badgeColor)
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 5)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                if let message = entry.message {
                                    Text(activityTitle(for: message))
                                        .font(.caption.weight(.medium))
                                }
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func activityTitle(for message: SocketMessage) -> String {
        switch message.type {
        case .updateTool:
            return "Tool: \(message.toolName ?? "unknown")"
        case .updateStatus:
            return "Status: \(message.status?.rawValue ?? "updated")"
        case .notification:
            return "Notification: \(message.notificationType ?? "event")"
        case .register:
            return "Agent registered"
        case .deregister:
            return "Agent deregistered"
        case .subagentStart:
            return "Subagent started"
        case .subagentStop:
            return "Subagent stopped"
        case .updateTokens:
            return "Token update"
        }
    }

    @MainActor
    private func refreshGitInfo() async {
        gitInfo = GitService.fetchInfo(for: cwd)
    }
}

private struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
