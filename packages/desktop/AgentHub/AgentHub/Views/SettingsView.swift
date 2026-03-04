import SwiftUI

struct SettingsView: View {
    let remoteHostManager: RemoteHostManager

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            RemoteHostsSettingsView(manager: remoteHostManager)
                .tabItem {
                    Label("Remote Hosts", systemImage: "network")
                }

            BeadsSettingsView()
                .tabItem {
                    Label("Beads", systemImage: "target")
                }
        }
        .frame(width: 420, height: 480)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @AppStorage("defaultTerminal") private var defaultTerminal: String = SupportedTerminal.terminal.rawValue
    @AppStorage("defaultIDE") private var defaultIDE: String = SupportedIDE.vscode.rawValue
    @AppStorage("summarizationBackend") private var summarizationBackend: String = SummarizationBackend.systemDefault.rawValue
    @AppStorage("openRouterAPIKey") private var openRouterAPIKey: String = ""
    @AppStorage("openRouterModel") private var openRouterModel: String = "google/gemini-2.5-flash-lite"
    @State private var hasBun = false
    @State private var cliInstalled = false
    @State private var cliNeedsUpdate = false
    @State private var claudeHooksInstalled = false
    @State private var openCodeHooksInstalled = false
    @State private var daemonRunning = false
    @State private var message: String?

    var body: some View {
        Form {
            Picker("Default Terminal", selection: $defaultTerminal) {
                ForEach(SupportedTerminal.allCases) { terminal in
                    Text(terminal.rawValue).tag(terminal.rawValue)
                }
            }

            Picker("Default IDE", selection: $defaultIDE) {
                ForEach(SupportedIDE.allCases) { ide in
                    Text(ide.rawValue).tag(ide.rawValue)
                }
            }

            Section("Notification Summaries") {
                Picker("Backend", selection: $summarizationBackend) {
                    ForEach(SummarizationBackend.availableCases) { backend in
                        Text(backend.rawValue).tag(backend.rawValue)
                    }
                }

                if summarizationBackend == SummarizationBackend.appleIntelligence.rawValue {
                    if !SummarizationBackend.isAppleIntelligenceReady {
                        Label("Apple Intelligence is not enabled. Enable it in System Settings → Apple Intelligence & Siri.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }

                if summarizationBackend == SummarizationBackend.openRouter.rawValue {
                    SecureField("OpenRouter API Key", text: $openRouterAPIKey)
                    TextField("Model", text: $openRouterModel)
                        .font(.caption)
                }
            }

            Section("AgentHub CLI & Hooks") {
                HStack {
                    Text("bun")
                    Spacer()
                    if hasBun {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("curl -fsSL https://bun.sh/install | bash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                }

                HStack {
                    Text("CLI Binary")
                    Spacer()
                    if cliInstalled {
                        Image(systemName: cliNeedsUpdate ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(cliNeedsUpdate ? .yellow : .green)
                        Button(cliNeedsUpdate ? "Update" : "Reinstall") { installCLI() }
                            .disabled(!hasBun)
                    } else {
                        Button("Install") { installCLI() }
                            .disabled(!hasBun)
                    }
                }

                HStack {
                    Text("Claude Code Hooks")
                    Spacer()
                    Image(systemName: claudeHooksInstalled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(claudeHooksInstalled ? .green : .secondary)
                    Button(claudeHooksInstalled ? "Reinstall" : "Install") { installClaudeHooks() }
                        .disabled(!cliInstalled)
                    if claudeHooksInstalled {
                        Button("Uninstall") { uninstallClaudeHooks() }
                    }
                }

                HStack {
                    Text("OpenCode Hooks")
                    Spacer()
                    Image(systemName: openCodeHooksInstalled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(openCodeHooksInstalled ? .green : .secondary)
                    Button(openCodeHooksInstalled ? "Reinstall" : "Install") { installOpenCodeHooks() }
                        .disabled(!cliInstalled)
                    if openCodeHooksInstalled {
                        Button("Uninstall") { uninstallOpenCodeHooks() }
                    }
                }

                HStack {
                    Text("Daemon")
                    Spacer()
                    if daemonRunning {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Running")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(.secondary)
                        Button("Start") { startDaemon() }
                            .disabled(!cliInstalled)
                    }
                }

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { checkStatus() }
    }

    private func checkStatus() {
        hasBun = HookInstaller.isCommandAvailable("bun")
        cliInstalled = HookInstaller.findBinary() != nil
        daemonRunning = HookInstaller.isDaemonRunning()

        switch HookInstaller.cliVersionStatus() {
        case .needsUpdate(let installedVersion, let expectedVersion):
            cliNeedsUpdate = true
            if let installedVersion {
                message = "CLI update available: installed \(installedVersion), expected \(expectedVersion)"
            } else {
                message = "CLI update available: installed version unknown, expected \(expectedVersion)"
            }
        case .upToDate:
            cliNeedsUpdate = false
        case .notInstalled:
            cliNeedsUpdate = false
        }
        claudeHooksInstalled = HookInstaller.isClaudeHooksInstalled()
        openCodeHooksInstalled = HookInstaller.isOpenCodeHooksInstalled()
    }

    private func installCLI() {
        message = nil
        guard let source = HookInstaller.findBinary() ?? (hasBun ? "" : nil) else {
            message = "bun is required to install the CLI"
            return
        }
        do {
            _ = try HookInstaller.installBinary(from: source)
            cliInstalled = true
            cliNeedsUpdate = false
            message = "CLI installed successfully"
        } catch {
            message = "Install failed: \(error.localizedDescription)"
        }
    }

    private func installClaudeHooks() {
        message = nil
        let result = HookInstaller.installClaude(binaryPath: "")
        if result.exitCode == 0 {
            message = "Installed Claude hooks."
        } else {
            message = result.stderr.isEmpty ? "Failed to install Claude hooks" : "Install failed: \(result.stderr)"
        }
        claudeHooksInstalled = HookInstaller.isClaudeHooksInstalled()
    }

    private func installOpenCodeHooks() {
        message = nil
        let result = HookInstaller.installOpenCode(binaryPath: "")
        if result.exitCode == 0 {
            message = "Installed OpenCode hooks."
        } else {
            message = result.stderr.isEmpty ? "Failed to install OpenCode hooks" : "Install failed: \(result.stderr)"
        }
        openCodeHooksInstalled = HookInstaller.isOpenCodeHooksInstalled()
    }

    private func uninstallClaudeHooks() {
        message = nil
        let result = HookInstaller.uninstallClaude()
        if result.exitCode == 0 {
            message = "Removed Claude hooks."
        } else {
            message = result.stderr.isEmpty ? "Failed to uninstall Claude hooks" : "Uninstall failed: \(result.stderr)"
        }
        claudeHooksInstalled = HookInstaller.isClaudeHooksInstalled()
    }

    private func uninstallOpenCodeHooks() {
        message = nil
        let result = HookInstaller.uninstallOpenCode()
        if result.exitCode == 0 {
            message = "Removed OpenCode hooks."
        } else {
            message = result.stderr.isEmpty ? "Failed to uninstall OpenCode hooks" : "Uninstall failed: \(result.stderr)"
        }
        openCodeHooksInstalled = HookInstaller.isOpenCodeHooksInstalled()
    }

    private func startDaemon() {
        message = nil
        let result = HookInstaller.startDaemon()
        if result.exitCode == 0 {
            message = "Daemon started."
        } else {
            message = result.stderr.isEmpty ? "Failed to start daemon" : "Failed to start daemon: \(result.stderr)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            daemonRunning = HookInstaller.isDaemonRunning()
        }
    }
}

// MARK: - Remote Hosts Settings

struct RemoteHostsSettingsView: View {
    let manager: RemoteHostManager
    @State private var showAddSheet = false
    @State private var editingHost: RemoteHost?
    @State private var showQRScanner = false
    @State private var agenthubKeys: [AgentHubSSHKey] = []

    var body: some View {
        Form {
            Section {
                if manager.hosts.isEmpty {
                    Text("No remote hosts configured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.hosts) { host in
                        remoteHostRow(host)
                    }
                }

                Button("Add Host...") {
                    showAddSheet = true
                }
            }

            Section("iOS Device Keys") {
                ForEach(agenthubKeys) { key in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.comment.isEmpty ? key.keyType : key.comment)
                                .font(.body.weight(.medium))
                            HStack(spacing: 4) {
                                Text(key.keyType)
                                Text(String(key.keyData.prefix(12)) + "..." + String(key.keyData.suffix(8)))
                            }
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            if let date = key.addedDate {
                                Text("Added \(formatDate(date))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            removeKey(key)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .controlSize(.small)
                    }
                }

                Button("Scan Key from iOS Device...") {
                    showQRScanner = true
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAddSheet) {
            RemoteHostEditSheet(manager: manager, host: nil)
        }
        .sheet(item: $editingHost) { host in
            RemoteHostEditSheet(manager: manager, host: host)
        }
        .sheet(isPresented: $showQRScanner) {
            QRKeyScannerView()
        }
        .onAppear { refreshKeys() }
        .onChange(of: showQRScanner) {
            if !showQRScanner { refreshKeys() }
        }
    }

    private func refreshKeys() {
        agenthubKeys = SSHKeyInstaller.agenthubKeys()
    }

    private func removeKey(_ key: AgentHubSSHKey) {
        try? SSHKeyInstaller.removeKey(key)
        refreshKeys()
    }

    private func formatDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return iso }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .short
        return display.string(from: date)
    }

    private func remoteHostRow(_ host: RemoteHost) -> some View {
        HStack {
            connectionDot(for: host)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.label)
                    .font(.body.weight(.medium))
                Text(host.sshDestination)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let conn = manager.connections[host.id],
                   case .error(let msg) = conn.status {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let conn = manager.connections[host.id], case .error = conn.status {
                Button("Retry") {
                    manager.retryConnection(host.id)
                }
                .controlSize(.small)
            }
            Button("Edit") {
                editingHost = host
            }
            .controlSize(.small)
            Button(role: .destructive) {
                manager.removeHost(host.id)
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
        }
    }

    private func connectionDot(for host: RemoteHost) -> some View {
        let color: Color = {
            guard let conn = manager.connections[host.id] else {
                return host.isEnabled ? .gray : .gray.opacity(0.3)
            }
            switch conn.status {
            case .connected: return .green
            case .connecting: return .yellow
            case .error: return .red
            case .disabled: return .gray.opacity(0.3)
            }
        }()
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}

struct RemoteHostEditSheet: View {
    let manager: RemoteHostManager
    let host: RemoteHost?
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var sshDestination = ""
    @State private var sshPort = "22"
    @State private var sshKeyPath = ""
    @State private var isEnabled = true

    var body: some View {
        VStack(spacing: 16) {
            Text(host == nil ? "Add Remote Host" : "Edit Remote Host")
                .font(.headline)

            Form {
                TextField("Label", text: $label, prompt: Text("Home Mac"))
                TextField("SSH Destination", text: $sshDestination, prompt: Text("user@hostname"))
                TextField("Port", text: $sshPort)
                TextField("SSH Key Path (optional)", text: $sshKeyPath, prompt: Text("~/.ssh/id_ed25519"))
                Toggle("Enabled", isOn: $isEnabled)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(host == nil ? "Add" : "Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(label.isEmpty || sshDestination.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            if let host {
                label = host.label
                sshDestination = host.sshDestination
                sshPort = "\(host.sshPort)"
                sshKeyPath = host.sshKeyPath ?? ""
                isEnabled = host.isEnabled
            }
        }
    }

    private func save() {
        let port = Int(sshPort) ?? 22
        let keyPath = sshKeyPath.isEmpty ? nil : sshKeyPath
        let updated = RemoteHost(
            id: host?.id ?? UUID(),
            label: label,
            sshDestination: sshDestination,
            sshPort: port,
            sshKeyPath: keyPath,
            isEnabled: isEnabled
        )
        if host != nil {
            manager.updateHost(updated)
        } else {
            manager.addHost(updated)
        }
    }
}

// MARK: - Beads Settings

struct BeadsSettingsView: View {
    @AppStorage("beadsImplementation") private var beadsImplementation: String = "br"

    @State private var bdInstalled = false
    @State private var brInstalled = false
    @State private var bvInstalled = false
    @State private var isInstalling: String?
    @State private var message: String?

    var body: some View {
        Form {
            Section("Default Implementation") {
                Picker("CLI Tool", selection: $beadsImplementation) {
                    ForEach(BeadsImplementation.allCases) { impl in
                        Text(impl.displayName).tag(impl.rawValue)
                    }
                }
                Text("Select which beads CLI to use for issue tracking operations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Beads CLI (bd)") {
                installRow(
                    name: "bd",
                    installed: bdInstalled,
                    description: "Python/Go — steveyegge/beads",
                    isInstalling: isInstalling == "bd"
                ) {
                    isInstalling = "bd"
                    message = nil
                    BeadsService.installBd { ok in
                        isInstalling = nil
                        bdInstalled = BeadsService.isBdInstalled()
                        message = ok ? "bd installed successfully." : "bd installation failed."
                    }
                }
            }

            Section("Beads Rust CLI (br)") {
                installRow(
                    name: "br",
                    installed: brInstalled,
                    description: "Rust — Dicklesworthstone/beads_rust",
                    isInstalling: isInstalling == "br"
                ) {
                    isInstalling = "br"
                    message = nil
                    BeadsService.installBr { ok in
                        isInstalling = nil
                        brInstalled = BeadsService.isBrInstalled()
                        message = ok ? "br installed successfully." : "br installation failed."
                    }
                }
            }

            Section("Beads Viewer (bv)") {
                installRow(
                    name: "bv",
                    installed: bvInstalled,
                    description: "Graph-aware TUI viewer",
                    isInstalling: isInstalling == "bv"
                ) {
                    isInstalling = "bv"
                    message = nil
                    BeadsService.installBv(viaHomebrew: true) { ok in
                        isInstalling = nil
                        bvInstalled = BeadsService.isBeadsViewerInstalled()
                        message = ok ? "bv installed successfully." : "bv installation failed. Try installing manually."
                    }
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { checkStatus() }
    }

    private func checkStatus() {
        bdInstalled = BeadsService.isBdInstalled()
        brInstalled = BeadsService.isBrInstalled()
        bvInstalled = BeadsService.isBeadsViewerInstalled()
    }

    private func installRow(name: String, installed: Bool, description: String, isInstalling: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isInstalling {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(installed ? .green : .secondary)
                Button(installed ? "Reinstall" : "Install") { action() }
            }
        }
    }
}
