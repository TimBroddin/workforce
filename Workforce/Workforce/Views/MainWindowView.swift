import SwiftUI

struct MainWindowView: View {
    let store: AgentStore
    @State private var selectedAgentId: String?
    @State private var collapsedCwds: Set<String> = []
    @AppStorage("defaultTerminal") private var defaultTerminal: String = SupportedTerminal.terminal.rawValue
    @AppStorage("defaultIDE") private var defaultIDE: String = SupportedIDE.vscode.rawValue
    @State private var agentToDelete: Agent?
    @State private var hasCodex = false
    @State private var hasOpenCode = false
    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false
    @State private var showSetupWizard = false

    /// Unique cwds from all active agents, sorted alphabetically
    private var cwds: [String] {
        Array(Set(store.sortedAgents.map(\.cwd))).sorted()
    }

    /// Agents grouped by cwd
    private func agents(for cwd: String) -> [Agent] {
        store.sortedAgents.filter { $0.cwd == cwd }
    }

    /// The effectively selected agent, falling back to the first sorted agent.
    private var selectedAgent: Agent? {
        if let selectedAgentId, let agent = store.agents[selectedAgentId] {
            return agent
        }
        return store.sortedAgents.first
    }

    /// Whether an agent is the currently selected one (matches visual highlight to actual selection).
    private func isSelected(_ agent: Agent) -> Bool {
        selectedAgent?.sessionId == agent.sessionId
    }

    var body: some View {
        VStack(spacing: 0) {
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
        .alert(
            "Delete Agent",
            isPresented: Binding(
                get: { agentToDelete != nil },
                set: { if !$0 { agentToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                agentToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let agent = agentToDelete {
                    store.killAgent(agent.sessionId)
                    agentToDelete = nil
                }
            }
        } message: {
            if let agent = agentToDelete {
                Text("This will kill the tmux session for \"\(agent.name)\" and remove it from the list.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusAgent)) { notification in
            if let sessionId = notification.userInfo?["sessionId"] as? String {
                selectedAgentId = sessionId
                NSApp.activate()
                for window in NSApp.windows {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
        .onChange(of: store.sortedAgents.map(\.sessionId)) {
            // Clear stale selection so the fallback to first agent kicks in
            if let selectedAgentId, store.agents[selectedAgentId] == nil {
                self.selectedAgentId = nil
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                store.pruneStale()
            }
        }
        .task {
            while !Task.isCancelled {
                store.refreshPaneTitles()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .task {
            let codex = Self.isCommandAvailable("codex")
            let opencode = Self.isCommandAvailable("opencode")
            await MainActor.run {
                hasCodex = codex
                hasOpenCode = opencode
            }
        }
        .sheet(isPresented: $showSetupWizard) {
            SetupWizardView(isPresented: $showSetupWizard)
        }
        .onAppear {
            if !hasCompletedSetup {
                showSetupWizard = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSetupWizard)) { _ in
            showSetupWizard = true
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        Group {
            if store.sortedAgents.isEmpty {
                VStack {
                    Spacer()
                    Text("No agents")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(cwds.enumerated()), id: \.element) { index, cwd in
                            if index > 0 {
                                Spacer().frame(height: 12)
                            }

                            sectionHeader(for: cwd)

                            if !collapsedCwds.contains(cwd) {
                                ForEach(agents(for: cwd)) { agent in
                                    AgentRowView(agent: agent)
                                        .background(
                                            isSelected(agent)
                                                ? Color.accentColor.opacity(0.1)
                                                : Color.clear
                                        )
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            selectedAgentId = agent.sessionId
                                        }
                                        .contextMenu {
                                            if let tmux = agent.tmuxSession {
                                                Button("Open in Terminal") {
                                                    let terminal = SupportedTerminal(rawValue: defaultTerminal) ?? .terminal
                                                    AppLauncher.openInTerminal(tmuxSession: tmux, terminal: terminal)
                                                }
                                                Button("Copy tmux Command") {
                                                    NSPasteboard.general.clearContents()
                                                    NSPasteboard.general.setString(
                                                        AppLauncher.tmuxAttachCommand(session: tmux),
                                                        forType: .string
                                                    )
                                                }
                                            }

                                            Divider()

                                            Button("Close") {
                                                store.removeAgent(agent.sessionId)
                                            }

                                            Button("Delete...", role: .destructive) {
                                                agentToDelete = agent
                                            }
                                        }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(for cwd: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: collapsedCwds.contains(cwd) ? "chevron.right" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 10)

            Image(systemName: "folder.fill")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(abbreviatePath(cwd))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Menu {
                Button("Claude") {
                    selectedAgentId = store.spawnAgent(cwd: cwd, agentType: "claude")
                }
                Button("Claude (--dangerously-skip-permissions)") {
                    selectedAgentId = store.spawnAgent(cwd: cwd, agentType: "claude --dangerously-skip-permissions")
                }
                if hasCodex {
                    Button("Codex") {
                        selectedAgentId = store.spawnAgent(cwd: cwd, agentType: "codex")
                    }
                }
                if hasOpenCode {
                    Button("OpenCode") {
                        selectedAgentId = store.spawnAgent(cwd: cwd, agentType: "opencode")
                    }
                }
                Divider()
                Button("Bash") {
                    selectedAgentId = store.spawnAgent(cwd: cwd, agentType: "bash")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("New agent in this directory")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if collapsedCwds.contains(cwd) {
                    collapsedCwds.remove(cwd)
                } else {
                    collapsedCwds.insert(cwd)
                }
            }
        }
        .contextMenu {
            let ide = SupportedIDE(rawValue: defaultIDE) ?? .vscode
            Button("Open in \(ide.rawValue)") {
                AppLauncher.openInIDE(path: cwd, ide: ide)
            }
            Button("Open in Finder") {
                AppLauncher.openInFinder(path: cwd)
            }
        }
    }

    // MARK: - Terminal Pane

    private var terminalPane: some View {
        Group {
            if let agent = selectedAgent {
                if let tmuxSession = agent.tmuxSession {
                    VStack(spacing: 0) {
                        tmuxToolbar(session: tmuxSession)
                        Divider()
                        TerminalRepresentable(sessionName: tmuxSession)
                            .id(agent.sessionId)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("No terminal available")
                            .foregroundStyle(.secondary)
                        Text("Start this session with `workforce` to enable the embedded terminal.")
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

    // MARK: - Tmux Toolbar

    private func tmuxToolbar(session: String) -> some View {
        HStack(spacing: 12) {
            Button {
                AppLauncher.runTmuxCommand(session: session, args: ["split-window", "-h"])
            } label: {
                Label("Split H", systemImage: "rectangle.split.2x1")
            }
            .help("Split Horizontally")

            Button {
                AppLauncher.runTmuxCommand(session: session, args: ["split-window", "-v"])
            } label: {
                Label("Split V", systemImage: "rectangle.split.1x2")
            }
            .help("Split Vertically")

            Button {
                AppLauncher.runTmuxCommand(session: session, args: ["kill-pane"])
            } label: {
                Label("Close Pane", systemImage: "xmark.square")
            }
            .help("Close Pane")

            Spacer()
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
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

    private static func isCommandAvailable(_ command: String) -> Bool {
        HookInstaller.isCommandAvailable(command)
    }
}
