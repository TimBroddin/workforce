import AppKit
import SwiftUI

struct MainWindowView: View {
    let store: AgentStore
    let eventLog: EventLog
    let remoteHostManager: RemoteHostManager
    let clientRegistry: ClientRegistry
    @State private var selectedAgentId: String?
    @State private var selectedFolderCwd: String?
    @State private var collapsedCwds: Set<String> = []
    @State private var collapsedHosts: Set<String> = []
    @AppStorage("defaultTerminal") private var defaultTerminal: String = SupportedTerminal.terminal.rawValue
    @AppStorage("defaultIDE") private var defaultIDE: String = SupportedIDE.vscode.rawValue
    @State private var agentToDelete: Agent?
    @State private var hasCodex = false
    @State private var hasOpenCode = false
    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false
    @AppStorage("followAgent") private var followAgent = false
    @AppStorage("showCosts") private var showCosts = true
    @State private var showSetupWizard = false
    @State private var showRecentEvents = false
    @State private var previousStatuses: [String: AgentStatus] = [:]
    @AppStorage("sidebarFolders") private var sidebarFoldersRaw = ""
    @State private var showAddHostSheet = false
    @State private var sidebarTab = 0

    /// Unique cwds from all active agents, sorted alphabetically
    private var activeCwds: [String] {
        Array(Set(store.sortedAgents.map(\.cwd))).sorted()
    }

    /// User-pinned folders in the sidebar.
    private var pinnedCwds: [String] {
        sidebarFoldersRaw
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
            .sorted()
    }

    /// Combined folders shown in the sidebar (pinned + active), sorted and de-duped.
    private var sidebarCwds: [String] {
        Array(Set(activeCwds + pinnedCwds)).sorted()
    }

    /// Agents grouped by cwd
    private func agents(for cwd: String) -> [Agent] {
        store.sortedAgents.filter { $0.cwd == cwd }
    }

    /// The effectively selected agent, falling back to the first sorted agent.
    private var selectedAgent: Agent? {
        if let selectedAgentId {
            if let agent = store.agents[selectedAgentId] {
                return agent
            }
            for conn in remoteHostManager.connections.values {
                if let agent = conn.agents.first(where: { $0.sessionId == selectedAgentId }) {
                    return agent
                }
            }
        }
        return store.sortedAgents.first
    }

    /// Whether an agent is the currently selected one (matches visual highlight to actual selection).
    private func isSelected(_ agent: Agent) -> Bool {
        guard selectedFolderCwd == nil else { return false }
        return selectedAgent?.sessionId == agent.sessionId
    }

    private var recentEvents: [EventLogEntry] {
        guard let sessionId = selectedAgent?.sessionId else { return [] }
        return Array(
            eventLog.entries
                .reversed()
                .filter { $0.message?.sessionId == sessionId }
                .prefix(20)
        )
    }

    private var selectedTmuxSession: String? {
        selectedAgent?.tmuxSession
    }

    private var statusSnapshots: [StatusSnapshot] {
        store.sortedAgents
            .map { StatusSnapshot(id: $0.sessionId, status: $0.status, lastActivityAt: $0.lastActivityAt) }
            .sorted { $0.id < $1.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content: sidebar + terminal
            HSplitView {
                sidebar
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 350)

                if let folderCwd = selectedFolderCwd, selectedAgentId == nil {
                    ProjectDetailView(cwd: folderCwd, store: store, eventLog: eventLog)
                } else {
                    terminalPane
                }
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
                Text("This will kill the tmux session for \"\(agent.displayTitle)\" and remove it from the list.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusAgent)) { notification in
            if let sessionId = notification.userInfo?["sessionId"] as? String {
                selectedAgentId = sessionId
                selectedFolderCwd = nil
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
        .onChange(of: statusSnapshots) { _, snapshots in
            guard followAgent else {
                previousStatuses = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.status) })
                return
            }

            let waiting = snapshots
                .filter { snapshot in
                    let was = previousStatuses[snapshot.id]
                    return (snapshot.status == .waitingForInput || snapshot.status == .waitingForPermission)
                        && was != snapshot.status
                }
                .max { $0.lastActivityAt < $1.lastActivityAt }

            if let waiting {
                selectedAgentId = waiting.id
                selectedFolderCwd = nil
            }

            previousStatuses = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.status) })
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
        .task {
            while !Task.isCancelled {
                for host in remoteHostManager.hosts where host.isEnabled {
                    remoteHostManager.pollAgents(hostId: host.id)
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .sheet(isPresented: $showSetupWizard) {
            SetupWizardView(isPresented: $showSetupWizard)
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if let session = selectedTmuxSession {
                    Button {
                        AppLauncher.runTmuxCommand(session: session, args: ["split-window", "-h"])
                    }
                    label: {
                        Label("Split H", systemImage: "rectangle.split.2x1")
                    }
                    .help("Split horizontally")

                    Button {
                        AppLauncher.runTmuxCommand(session: session, args: ["split-window", "-v"])
                    }
                    label: {
                        Label("Split V", systemImage: "rectangle.split.1x2")
                    }
                    .help("Split vertically")

                    Button {
                        AppLauncher.runTmuxCommand(session: session, args: ["kill-pane"])
                    }
                    label: {
                        Label("Close Pane", systemImage: "xmark.square")
                    }
                    .help("Close pane")
                }
            }

            ToolbarItemGroup(placement: .automatic) {
                if let session = selectedTmuxSession {
                    Button {
                        AppLauncher.sendTmuxInput(session: session, input: "/clear")
                    }
                    label: {
                        Label("/clear", systemImage: "eraser")
                    }
                    .help("Send /clear to Claude Code")

                    Button {
                        AppLauncher.sendTmuxInput(session: session, input: "/compact")
                    }
                    label: {
                        Label("/compact", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .help("Send /compact to Claude Code")
                }
            }

            ToolbarItemGroup(placement: .automatic) {
                Toggle(isOn: $followAgent) {
                    Label("Follow Agent", systemImage: "scope")
                }
                .help("Automatically select agents when they start waiting")

                Toggle(isOn: $showCosts) {
                    Label("Show Costs", systemImage: "dollarsign.circle")
                }
                .help("Show estimated token costs")

                Button {
                    showRecentEvents.toggle()
                } label: {
                    Label("Recent Events", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                .help("Show recent events for the selected agent")
                .popover(isPresented: $showRecentEvents, arrowEdge: .bottom) {
                    recentEventsPopover
                }
            }
        }
        .onAppear {
            switch HookInstaller.cliVersionStatus() {
            case .needsUpdate:
                showSetupWizard = true
            case .upToDate, .notInstalled:
                break
            }
            previousStatuses = Dictionary(
                uniqueKeysWithValues: store.sortedAgents.map { ($0.sessionId, $0.status) }
            )
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
        VStack(spacing: 0) {
            Picker("", selection: $sidebarTab) {
                Text("Local").tag(0)
                Text("Remote").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if sidebarTab == 0 {
                        localSidebarContent
                    } else {
                        remoteSidebarContent
                    }
                }
            }
        }
        .sheet(isPresented: $showAddHostSheet) {
            RemoteHostEditSheet(manager: remoteHostManager, host: nil)
        }
    }

    // MARK: - Local Sidebar Content

    @ViewBuilder
    private var localSidebarContent: some View {
        HStack {
            Spacer()
            Button {
                addFolderToSidebar()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Add folder to sidebar")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)

        if sidebarCwds.isEmpty {
            Text("No local folders")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        } else {
            ForEach(Array(sidebarCwds.enumerated()), id: \.element) { index, cwd in
                if index > 0 {
                    Spacer().frame(height: 12)
                }

                sectionHeader(for: cwd)

                if !collapsedCwds.contains(cwd) {
                    let cwdAgents = agents(for: cwd)
                    if cwdAgents.isEmpty {
                        Text("No running agents")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(cwdAgents) { agent in
                            localAgentRow(agent)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Remote Sidebar Content

    @ViewBuilder
    private var remoteSidebarContent: some View {
        HStack {
            Spacer()
            Button {
                showAddHostSheet = true
            } label: {
                Image(systemName: "network.badge.shield.half.filled")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Connect to remote host")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)

        let enabledRemoteHosts = remoteHostManager.hosts.filter(\.isEnabled)
        if enabledRemoteHosts.isEmpty {
            Text("No remote hosts")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        } else {
            ForEach(enabledRemoteHosts) { host in
                remoteHostHeader(host)

                if !collapsedHosts.contains(host.id.uuidString) {
                    remoteHostContent(host)
                }
            }
        }

        // Connected clients section
        let connectedClients = clientRegistry.connectedClients
        if !connectedClients.isEmpty {
            Spacer().frame(height: 16)

            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Connected Clients")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(connectedClients.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            ForEach(connectedClients) { client in
                HStack(spacing: 6) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text(client.displayName)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }


    // MARK: - Local Agent Row

    private func localAgentRow(_ agent: Agent) -> some View {
        AgentRowView(agent: agent)
            .background(
                isSelected(agent)
                    ? Color.accentColor.opacity(0.1)
                    : Color.clear
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selectedAgentId = agent.sessionId
                selectedFolderCwd = nil
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

    // MARK: - Remote Host Header & Content

    private func remoteHostHeader(_ host: RemoteHost) -> some View {
        let conn = remoteHostManager.connections[host.id]
        let status = conn?.status ?? .disabled

        return HStack(spacing: 6) {
            Image(systemName: collapsedHosts.contains(host.id.uuidString) ? "chevron.right" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .contentShape(Rectangle().inset(by: -4))
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if collapsedHosts.contains(host.id.uuidString) {
                            collapsedHosts.remove(host.id.uuidString)
                        } else {
                            collapsedHosts.insert(host.id.uuidString)
                        }
                    }
                }

            Circle()
                .fill(connectionStatusColor(status))
                .frame(width: 8, height: 8)

            Text(host.label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if case .error = status {
                Button {
                    remoteHostManager.retryConnection(host.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Retry connection")
            }

            let remoteCount = remoteAgents(for: host.id).count
            if remoteCount > 0 {
                Text("\(remoteCount)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            if status == .connected {
                Menu {
                    Button("Claude") {
                        spawnRemoteAgent(host: host, agentType: "claude")
                    }
                    Button("Claude (--dangerously-skip-permissions)") {
                        spawnRemoteAgent(host: host, agentType: "claude --dangerously-skip-permissions")
                    }
                    Divider()
                    Button("Bash") {
                        spawnRemoteAgent(host: host, agentType: "bash")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("New agent on \(host.label)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private func remoteHostContent(_ host: RemoteHost) -> some View {
        let conn = remoteHostManager.connections[host.id]
        let status = conn?.status ?? .disabled

        switch status {
        case .connected:
            let cwds = remoteCwds(for: host.id)
            if cwds.isEmpty {
                Text("No running agents")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(cwds.enumerated()), id: \.element) { index, cwd in
                    if index > 0 {
                        Spacer().frame(height: 8)
                    }

                    // Simple folder label for remote cwds
                    HStack(spacing: 6) {
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
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)

                    ForEach(remoteAgents(for: host.id, cwd: cwd)) { agent in
                        remoteAgentRow(agent)
                    }
                }
            }
        case .connecting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        case .error(let message):
            Text(message)
                .font(.caption2)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        case .disabled:
            Text("Disabled")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    private func remoteAgentRow(_ agent: Agent) -> some View {
        AgentRowView(agent: agent)
            .background(
                isSelected(agent)
                    ? Color.accentColor.opacity(0.1)
                    : Color.clear
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selectedAgentId = agent.sessionId
                selectedFolderCwd = nil
            }
            .contextMenu {
                if let tmux = agent.tmuxSession, let host = agent.host {
                    Button("Copy SSH Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "ssh -t \(host) tmux -u attach -t \(tmux)",
                            forType: .string
                        )
                    }
                }

                Divider()

                Button("Close") {
                    // Remove from local view only — remote agents are managed by remote host
                    if let hostId = remoteHostManager.hosts.first(where: { $0.sshDestination == agent.host })?.id {
                        remoteHostManager.connections[hostId]?.agents.removeAll { $0.sessionId == agent.sessionId }
                    }
                }
            }
    }

    // MARK: - Remote Agent Helpers

    private func remoteAgents(for hostId: UUID) -> [Agent] {
        remoteHostManager.connections[hostId]?.agents ?? []
    }

    private func remoteCwds(for hostId: UUID) -> [String] {
        Array(Set(remoteAgents(for: hostId).map(\.cwd))).sorted()
    }

    private func remoteAgents(for hostId: UUID, cwd: String) -> [Agent] {
        remoteAgents(for: hostId).filter { $0.cwd == cwd }
    }

    private func connectionStatusColor(_ status: ConnectionStatus) -> Color {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .error: return .red
        case .disabled: return .gray
        }
    }

    private func spawnRemoteAgent(host: RemoteHost, agentType: String) {
        remoteHostManager.spawnAgent(host: host, cwd: "~", agentType: agentType) { result in
            switch result {
            case .success:
                // Agent will appear on next poll
                remoteHostManager.pollAgents(hostId: host.id)
            case .failure:
                break
            }
        }
    }

    private func sectionHeader(for cwd: String) -> some View {
        HStack(spacing: 6) {
            // Chevron: toggles collapse
            Image(systemName: collapsedCwds.contains(cwd) ? "chevron.right" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .contentShape(Rectangle().inset(by: -4))
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if collapsedCwds.contains(cwd) {
                            collapsedCwds.remove(cwd)
                        } else {
                            collapsedCwds.insert(cwd)
                        }
                    }
                }

            // Folder name: selects the folder detail view
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(selectedFolderCwd == cwd && selectedAgentId == nil ? .primary : .secondary)

                Text(abbreviatePath(cwd))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(selectedFolderCwd == cwd && selectedAgentId == nil ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selectedAgentId = nil
                selectedFolderCwd = cwd
            }

            Spacer()

            if showCosts {
                let folderCost = agents(for: cwd).reduce(0.0) { total, agent in
                    total + CostCalculator.estimateCost(
                        model: agent.model,
                        inputTokens: agent.totalInputTokens,
                        outputTokens: agent.totalOutputTokens,
                        cacheCreationTokens: agent.totalCacheCreationTokens,
                        cacheReadTokens: agent.totalCacheReadTokens
                    )
                }
                if folderCost > 0 {
                    Text(CostCalculator.formatCost(folderCost))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            Menu {
                Button("Claude") {
                    selectedAgentId = store.spawnAgent(cwd: cwd, agentType: "claude")
                    selectedFolderCwd = nil
                }
                Button("Claude (--dangerously-skip-permissions)") {
                    selectedAgentId = store.spawnAgent(cwd: cwd, agentType: "claude --dangerously-skip-permissions")
                    selectedFolderCwd = nil
                }
                if hasCodex {
                    Button("Codex") {
                        selectedAgentId = store.spawnAgent(cwd: cwd, agentType: "codex")
                        selectedFolderCwd = nil
                    }
                }
                if hasOpenCode {
                    Button("OpenCode") {
                        selectedAgentId = store.spawnAgent(cwd: cwd, agentType: "opencode")
                        selectedFolderCwd = nil
                    }
                }
                Divider()
                Button("Bash") {
                    selectedAgentId = store.spawnAgent(cwd: cwd, agentType: "bash")
                    selectedFolderCwd = nil
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
        .background(
            selectedFolderCwd == cwd && selectedAgentId == nil
                ? Color.accentColor.opacity(0.08)
                : Color(nsColor: .controlBackgroundColor).opacity(0.5)
        )
        .contextMenu {
            let ide = SupportedIDE(rawValue: defaultIDE) ?? .vscode
            Button("Open in \(ide.rawValue)") {
                AppLauncher.openInIDE(path: cwd, ide: ide)
            }
            Button("Open in Finder") {
                AppLauncher.openInFinder(path: cwd)
            }
            if pinnedCwds.contains(cwd) {
                Divider()
                Button("Remove from Sidebar") {
                    removePinnedFolder(cwd)
                }
            }
        }
    }

    // MARK: - Terminal Pane

    private var terminalPane: some View {
        Group {
            if let agent = selectedAgent {
                if let tmuxSession = agent.tmuxSession {
                    TerminalRepresentable(
                        sessionName: tmuxSession,
                        host: agent.host,
                        sshPort: agent.host != nil
                            ? remoteHostManager.hosts.first(where: { $0.sshDestination == agent.host })?.sshPort
                            : nil
                    )
                        .id(agent.host != nil ? "\(agent.host!)-\(agent.sessionId)" : agent.sessionId)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - Footer

    private var footer: some View {
        HStack {
            let localCount = store.agents.count
            let remoteCount = remoteHostManager.allRemoteAgents.count
            let total = localCount + remoteCount
            Text("\(total) agent\(total == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if showCosts {
                let allAgents = store.sortedAgents + remoteHostManager.allRemoteAgents
                let totalCost = allAgents.reduce(0.0) { total, agent in
                    total + CostCalculator.estimateCost(
                        model: agent.model,
                        inputTokens: agent.totalInputTokens,
                        outputTokens: agent.totalOutputTokens,
                        cacheCreationTokens: agent.totalCacheCreationTokens,
                        cacheReadTokens: agent.totalCacheReadTokens
                    )
                }
                if totalCost > 0 {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(CostCalculator.formatCost(totalCost))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
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

    private var recentEventsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let agent = selectedAgent {
                Text("Recent events for \(agent.displayTitle)")
                    .font(.headline)
            } else {
                Text("No agent selected")
                    .font(.headline)
            }

            if recentEvents.isEmpty {
                Text("No recent events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(recentEvents) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                if let message = entry.message {
                                    Circle()
                                        .fill(message.type.badgeColor)
                                        .frame(width: 8, height: 8)
                                        .padding(.top, 4)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(eventTitle(for: entry))
                                        .font(.caption.weight(.semibold))
                                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private func eventTitle(for entry: EventLogEntry) -> String {
        guard let message = entry.message else {
            return entry.error ?? "Invalid event"
        }
        switch message.type {
        case .updateTool:
            return "Tool: \(message.toolName ?? "unknown")"
        case .updateStatus:
            return "Status: \(statusLabel(message.status) ?? "updated")"
        case .notification:
            return "Notification: \(message.notificationType ?? "event")"
        default:
            return message.type.rawValue
        }
    }

    private static func isCommandAvailable(_ command: String) -> Bool {
        HookInstaller.isCommandAvailable(command)
    }

    private func addFolderToSidebar() {
        let panel = NSOpenPanel()
        panel.prompt = "Add Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            var updated = Set(pinnedCwds)
            updated.insert(url.path)
            sidebarFoldersRaw = updated.sorted().joined(separator: "\n")
        }
    }

    private func removePinnedFolder(_ cwd: String) {
        var updated = Set(pinnedCwds)
        updated.remove(cwd)
        sidebarFoldersRaw = updated.sorted().joined(separator: "\n")
    }

    private func statusLabel(_ status: AgentStatus?) -> String? {
        guard let status else { return nil }
        switch status {
        case .active: return "Active"
        case .idle: return "Idle"
        case .waitingForInput: return "Waiting for Input"
        case .waitingForPermission: return "Waiting for Permission"
        case .stopped: return "Stopped"
        }
    }

    private struct StatusSnapshot: Equatable {
        let id: String
        let status: AgentStatus
        let lastActivityAt: Date
    }
}
