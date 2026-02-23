import SwiftUI

struct ProjectDetailView: View {
    let cwd: String
    let store: AgentStore
    let eventLog: EventLog
    @State private var selectedTab = 0
    @State private var gitInfo: GitInfo?
    @State private var hasBeads = false
    @AppStorage("showCosts") private var showCosts = true

    private var projectAgents: [Agent] {
        store.sortedAgents.filter { $0.cwd == cwd }
    }

    private var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    private var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd.hasPrefix(home) {
            return "~" + cwd.dropFirst(home.count)
        }
        return cwd
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()
            tabContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await refreshGitInfo() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await refreshGitInfo()
            }
        }
        .onAppear { hasBeads = BeadsService.hasBeadsFolder(at: cwd) }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.blue.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(projectName)
                        .font(.title3.weight(.semibold))
                    Text(abbreviatedPath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                HStack(spacing: 12) {
                    statusPill(
                        count: projectAgents.filter { $0.status == .active }.count,
                        label: "active",
                        color: .green
                    )
                    statusPill(
                        count: projectAgents.filter { $0.status == .idle }.count,
                        label: "idle",
                        color: .gray
                    )
                    statusPill(
                        count: projectAgents.filter {
                            $0.status == .waitingForInput || $0.status == .waitingForPermission
                        }.count,
                        label: "waiting",
                        color: .blue
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func statusPill(count: Int, label: String, color: Color) -> some View {
        Group {
            if count > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                    Text("\(count) \(label)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(title: "Stats", icon: "chart.bar.fill", tag: 0)
            tabButton(title: "Git", icon: "arrow.triangle.branch", tag: 1)
            tabButton(title: "Activity", icon: "bolt.fill", tag: 2)
            if hasBeads {
                tabButton(title: "Issues", icon: "target", tag: 3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func tabButton(title: String, icon: String, tag: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = tag
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(selectedTab == tag ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                selectedTab == tag
                    ? Color.accentColor.opacity(0.1)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case 0: statsTab
        case 1: gitTab
        case 2: activityTab
        case 3: BeadsViewerView(cwd: cwd)
        default: EmptyView()
        }
    }

    // MARK: - Stats Tab

    private var statsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let totalInput = projectAgents.reduce(0) { $0 + $1.totalInputTokens }
                let totalOutput = projectAgents.reduce(0) { $0 + $1.totalOutputTokens }
                let totalCacheCreate = projectAgents.reduce(0) { $0 + $1.totalCacheCreationTokens }
                let totalCacheRead = projectAgents.reduce(0) { $0 + $1.totalCacheReadTokens }
                let totalCost = projectAgents.reduce(0.0) { total, agent in
                    total + CostCalculator.estimateCost(
                        model: agent.model,
                        inputTokens: agent.totalInputTokens,
                        outputTokens: agent.totalOutputTokens,
                        cacheCreationTokens: agent.totalCacheCreationTokens,
                        cacheReadTokens: agent.totalCacheReadTokens
                    )
                }

                // Summary cards
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    StatCard(
                        icon: "arrow.down.circle.fill",
                        iconColor: .blue,
                        title: "Input",
                        value: CostCalculator.formatTokens(totalInput)
                    )
                    StatCard(
                        icon: "arrow.up.circle.fill",
                        iconColor: .purple,
                        title: "Output",
                        value: CostCalculator.formatTokens(totalOutput)
                    )
                    if totalCacheCreate + totalCacheRead > 0 {
                        StatCard(
                            icon: "memorychip.fill",
                            iconColor: .orange,
                            title: "Cache",
                            value: CostCalculator.formatTokens(totalCacheCreate + totalCacheRead)
                        )
                    }
                    if showCosts {
                        StatCard(
                            icon: "dollarsign.circle.fill",
                            iconColor: .green,
                            title: "Cost",
                            value: totalCost > 0 ? CostCalculator.formatCost(totalCost) : "—"
                        )
                    }
                }

                // Per-agent breakdown
                if !projectAgents.isEmpty {
                    sectionLabel("Agents")

                    VStack(spacing: 1) {
                        ForEach(projectAgents) { agent in
                            agentStatsRow(agent)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(16)
        }
    }

    private func agentStatsRow(_ agent: Agent) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(agentStatusColor(agent.status))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayTitle)
                    .font(.callout.weight(.medium))
                HStack(spacing: 6) {
                    if let model = agent.model {
                        Text(model)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(agentStatusLabel(agent.status))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            let tokens = agent.totalInputTokens + agent.totalOutputTokens
            if tokens > 0 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(CostCalculator.formatTokens(tokens))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                    if showCosts {
                        let cost = CostCalculator.estimateCost(
                            model: agent.model,
                            inputTokens: agent.totalInputTokens,
                            outputTokens: agent.totalOutputTokens,
                            cacheCreationTokens: agent.totalCacheCreationTokens,
                            cacheReadTokens: agent.totalCacheReadTokens
                        )
                        Text(CostCalculator.formatCost(cost))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Git Tab

    private var gitTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let info = gitInfo {
                    // Branch card
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.purple.opacity(0.12))
                                .frame(width: 30, height: 30)
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.purple)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.branch)
                                .font(.callout.weight(.semibold))
                            if info.dirtyFileCount > 0 {
                                Text("\(info.dirtyFileCount) uncommitted change\(info.dirtyFileCount == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            } else {
                                Text("Clean working tree")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                        }

                        Spacer()
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    // Commit log
                    if !info.recentCommits.isEmpty {
                        sectionLabel("Recent Commits")

                        VStack(spacing: 0) {
                            ForEach(Array(info.recentCommits.enumerated()), id: \.element.id) { index, commit in
                                HStack(alignment: .top, spacing: 10) {
                                    // Timeline
                                    VStack(spacing: 0) {
                                        Circle()
                                            .fill(index == 0 ? Color.accentColor : Color.secondary.opacity(0.3))
                                            .frame(width: 8, height: 8)
                                        if index < info.recentCommits.count - 1 {
                                            Rectangle()
                                                .fill(.quaternary)
                                                .frame(width: 1)
                                        }
                                    }
                                    .frame(width: 8)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(commit.message)
                                            .font(.callout)
                                            .lineLimit(2)
                                        Text(commit.id)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.bottom, 12)

                                    Spacer()
                                }
                            }
                        }
                    }
                } else {
                    emptyState(
                        icon: "arrow.triangle.branch",
                        title: "Not a Git Repository",
                        subtitle: "This folder is not tracked by Git."
                    )
                }
            }
            .padding(16)
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
            LazyVStack(alignment: .leading, spacing: 0) {
                if projectEntries.isEmpty {
                    emptyState(
                        icon: "bolt.slash",
                        title: "No Recent Activity",
                        subtitle: "Events from agents in this project will appear here."
                    )
                    .padding(.top, 40)
                } else {
                    ForEach(projectEntries) { entry in
                        activityRow(entry)
                        if entry.id != projectEntries.last?.id {
                            Divider()
                                .padding(.leading, 36)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func activityRow(_ entry: EventLogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let message = entry.message {
                ZStack {
                    Circle()
                        .fill(message.type.badgeColor.opacity(0.15))
                        .frame(width: 24, height: 24)
                    Image(systemName: activityIcon(for: message.type))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(message.type.badgeColor)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                if let message = entry.message {
                    Text(activityTitle(for: message))
                        .font(.callout.weight(.medium))
                }
                Text(relativeTime(entry.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }

    // MARK: - Shared Components

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.quaternary)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Helpers

    private func activityTitle(for message: SocketMessage) -> String {
        switch message.type {
        case .updateTool:
            return message.toolName ?? "Tool use"
        case .updateStatus:
            return "Status: \(message.status?.rawValue ?? "updated")"
        case .notification:
            return message.notificationType == "permission_prompt"
                ? "Permission requested"
                : message.notificationType ?? "Notification"
        case .register:
            return "Agent started"
        case .deregister:
            return "Agent stopped"
        case .subagentStart:
            return "Subagent spawned"
        case .subagentStop:
            return "Subagent finished"
        case .updateTokens:
            return "Token usage reported"
        }
    }

    private func activityIcon(for type: SocketMessageType) -> String {
        switch type {
        case .register: "play.fill"
        case .deregister: "stop.fill"
        case .updateTool: "wrench.fill"
        case .updateStatus: "arrow.triangle.2.circlepath"
        case .notification: "bell.fill"
        case .subagentStart: "cpu"
        case .subagentStop: "cpu"
        case .updateTokens: "number"
        }
    }

    private func agentStatusColor(_ status: AgentStatus) -> Color {
        switch status {
        case .active: .green
        case .waitingForInput, .waitingForPermission: .blue
        case .idle: .gray
        case .stopped: .gray.opacity(0.4)
        }
    }

    private func agentStatusLabel(_ status: AgentStatus) -> String {
        switch status {
        case .active: "Working"
        case .waitingForInput: "Waiting for input"
        case .waitingForPermission: "Waiting for permission"
        case .idle: "Idle"
        case .stopped: "Stopped"
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    @MainActor
    private func refreshGitInfo() async {
        gitInfo = GitService.fetchInfo(for: cwd)
    }
}

// MARK: - Stat Card

private struct StatCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.3)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
