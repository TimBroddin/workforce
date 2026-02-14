import SwiftUI

struct MainWindowView: View {
    let store: AgentStore
    @State private var selectedCwd: String?
    @State private var selectedAgentId: String?

    /// Unique cwds from all active agents, sorted alphabetically
    private var cwds: [String] {
        Array(Set(store.sortedAgents.map(\.cwd))).sorted()
    }

    /// Agents filtered to the selected cwd tab
    private var filteredAgents: [Agent] {
        guard let cwd = effectiveCwd else { return [] }
        return store.sortedAgents.filter { $0.cwd == cwd }
    }

    /// Effective cwd: selected if still valid, otherwise first available
    private var effectiveCwd: String? {
        if let selectedCwd, cwds.contains(selectedCwd) {
            return selectedCwd
        }
        return cwds.first
    }

    private var selectedAgent: Agent? {
        guard let selectedAgentId else { return filteredAgents.first }
        return store.agents[selectedAgentId]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            tabBar

            Divider()

            // Content: sidebar + terminal
            HSplitView {
                sidebar
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 350)

                terminalPane
            }

            Divider()

            // Footer
            footer
        }
        .frame(minWidth: 800, minHeight: 500)
        .onChange(of: cwds) { _, newCwds in
            if let selectedCwd, !newCwds.contains(selectedCwd) {
                self.selectedCwd = newCwds.first
                self.selectedAgentId = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusAgent)) { notification in
            if let sessionId = notification.userInfo?["sessionId"] as? String,
               let agent = store.agents[sessionId] {
                selectedCwd = agent.cwd
                selectedAgentId = agent.sessionId
                NSApp.activate()
                for window in NSApp.windows {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                store.pruneStale()
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(cwds, id: \.self) { cwd in
                    Button {
                        selectedCwd = cwd
                        selectedAgentId = nil
                    } label: {
                        Text(abbreviatePath(cwd))
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                effectiveCwd == cwd
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.clear
                            )
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        Group {
            if filteredAgents.isEmpty {
                VStack {
                    Spacer()
                    Text("No agents")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredAgents) { agent in
                            AgentRowView(agent: agent)
                                .background(
                                    selectedAgentId == agent.sessionId
                                        ? Color.accentColor.opacity(0.1)
                                        : Color.clear
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedAgentId = agent.sessionId
                                }
                            Divider().padding(.horizontal, 8)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Terminal Pane

    private var terminalPane: some View {
        Group {
            if let agent = selectedAgent {
                if let tmuxSession = agent.tmuxSession {
                    TerminalRepresentable(sessionName: tmuxSession)
                        .id(agent.sessionId)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("No terminal available")
                            .foregroundStyle(.secondary)
                        Text("Start this session with `workforce run` to enable the embedded terminal.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "person.3.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No agent selected")
                        .foregroundStyle(.secondary)
                    Text("Start a Claude Code session to see it here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(store.agents.count) agent\(store.agents.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            HookStatusView()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
