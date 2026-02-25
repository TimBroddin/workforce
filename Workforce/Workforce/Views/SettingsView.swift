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
    @AppStorage("listenOnAllInterfaces") private var listenOnAllInterfaces: Bool = false

    @State private var cliInstalled = false
    @State private var cliNeedsUpdate = false
    @State private var claudeHooksInstalled = false
    @State private var openCodeHooksInstalled = false
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

            Section("Network") {
                Toggle("Listen on all interfaces", isOn: $listenOnAllInterfaces)
                Text("When enabled, the API is accessible from other devices on your network. Requires app restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if listenOnAllInterfaces {
                    Label("You probably don't need this. Remote hosts are accessed via SSH tunnels which work with localhost. Only enable this if you have a specific reason to expose the API on your network.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            Section("Workforce CLI & Hooks") {
                HStack {
                    Text("CLI Binary")
                    Spacer()
                    if cliInstalled {
                        Image(systemName: cliNeedsUpdate ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(cliNeedsUpdate ? .yellow : .green)
                        Button(cliNeedsUpdate ? "Update" : "Reinstall") { installCLI() }
                            .disabled(HookInstaller.findBinary() == nil)
                    } else {
                        Button("Install") { installCLI() }
                            .disabled(HookInstaller.findBinary() == nil)
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
        cliInstalled = FileManager.default.isExecutableFile(atPath: "/usr/local/bin/workforce")
        switch HookInstaller.cliVersionStatus() {
        case .needsUpdate(let installedVersion, let appVersion):
            cliNeedsUpdate = true
            if let installedVersion {
                message = "CLI update available: installed \(installedVersion), app \(appVersion)"
            } else {
                message = "CLI update available: installed version unknown, app \(appVersion)"
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
        guard let source = HookInstaller.findBinary() else {
            message = "workforce binary not found"
            return
        }
        do {
            _ = try HookInstaller.installBinary(from: source)
            cliInstalled = true
            cliNeedsUpdate = false
            message = "CLI installed to /usr/local/bin/workforce"
        } catch {
            message = "Install failed: \(error.localizedDescription)"
        }
    }

    private func installClaudeHooks() {
        do {
            let count = try HookInstaller.installClaude(binaryPath: "/usr/local/bin/workforce")
            claudeHooksInstalled = HookInstaller.isClaudeHooksInstalled()
            message = count > 0 ? "Installed Claude hooks." : "Claude hooks already installed."
        } catch {
            message = "Install failed: \(error.localizedDescription)"
        }
    }

    private func installOpenCodeHooks() {
        do {
            let count = try HookInstaller.installOpenCode(binaryPath: "/usr/local/bin/workforce")
            openCodeHooksInstalled = HookInstaller.isOpenCodeHooksInstalled()
            message = count > 0 ? "Installed OpenCode hooks." : "OpenCode hooks already installed."
        } catch {
            message = "Install failed: \(error.localizedDescription)"
        }
    }

    private func uninstallClaudeHooks() {
        do {
            _ = try HookInstaller.uninstallClaude()
            claudeHooksInstalled = HookInstaller.isClaudeHooksInstalled()
            message = "Removed Claude hooks."
        } catch {
            message = "Uninstall failed: \(error.localizedDescription)"
        }
    }

    private func uninstallOpenCodeHooks() {
        do {
            _ = try HookInstaller.uninstallOpenCode()
            openCodeHooksInstalled = HookInstaller.isOpenCodeHooksInstalled()
            message = "Removed OpenCode hooks."
        } catch {
            message = "Uninstall failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Remote Hosts Settings

struct RemoteHostsSettingsView: View {
    let manager: RemoteHostManager
    @State private var showAddSheet = false
    @State private var editingHost: RemoteHost?

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
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAddSheet) {
            RemoteHostEditSheet(manager: manager, host: nil)
        }
        .sheet(item: $editingHost) { host in
            RemoteHostEditSheet(manager: manager, host: host)
        }
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
