import SwiftUI

struct SetupWizardView: View {
    @Binding var isPresented: Bool
    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false

    // Prereq status
    @State private var hasBun = false
    @State private var hasClaude = false

    // Install status
    @State private var cliInstalled = false
    @State private var cliNeedsUpdate = false
    @State private var claudeHooksInstalled = false
    @State private var openCodeHooksInstalled = false
    @State private var daemonRunning = false
    @State private var installError: String?
    @State private var cliUpdateMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heroSection
                Divider()
                prerequisitesSection
                Divider()
                installSection
                Divider()
                usageSection
            }
            .padding(32)
        }
        .frame(width: 520, height: 620)
        .task { checkStatus() }
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Spacer()
                    Button("Get Started") {
                        hasCompletedSetup = true
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("Welcome to AgentHub")
                .font(.title)
                .fontWeight(.bold)

            Text("AgentHub monitors your Claude Code sessions in real-time. It tracks agents, subagents, tool usage, and notifications — all in one window.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Prerequisites

    private var prerequisitesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prerequisites")
                .font(.headline)

            statusRow(
                name: "bun",
                installed: hasBun,
                hint: "curl -fsSL https://bun.sh/install | bash"
            )
            statusRow(
                name: "Claude CLI",
                installed: hasClaude,
                hint: "See claude.ai/download"
            )
        }
    }

    private func statusRow(name: String, installed: Bool, hint: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(installed ? .green : .yellow)
                .frame(width: 20)

            Text(name)
                .fontWeight(.medium)

            Spacer()

            if !installed {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Install

    private var installSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setup")
                .font(.headline)

            // 1. AgentHub CLI
            HStack(spacing: 8) {
                Image(systemName: cliInstalled ? (cliNeedsUpdate ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.circle.fill") : "circle")
                    .foregroundStyle(cliInstalled ? (cliNeedsUpdate ? .yellow : .green) : .secondary)
                    .frame(width: 20)

                Text("AgentHub CLI")
                    .fontWeight(.medium)

                Spacer()

                if !cliInstalled {
                    Button("Install") { installCLI() }
                        .disabled(!hasBun)
                } else if cliNeedsUpdate {
                    Button("Update") { installCLI() }
                        .disabled(!hasBun)
                }
            }

            // 2. Claude Code Hooks
            HStack(spacing: 8) {
                Image(systemName: claudeHooksInstalled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(claudeHooksInstalled ? .green : .secondary)
                    .frame(width: 20)

                Text("Claude Code Hooks")
                    .fontWeight(.medium)

                Spacer()

                Button(claudeHooksInstalled ? "Reinstall" : "Install") { installClaudeHooks() }
                    .disabled(!cliInstalled)
                if claudeHooksInstalled {
                    Button("Uninstall") { uninstallClaudeHooks() }
                }
            }

            // 3. OpenCode Hooks
            HStack(spacing: 8) {
                Image(systemName: openCodeHooksInstalled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(openCodeHooksInstalled ? .green : .secondary)
                    .frame(width: 20)

                Text("OpenCode Hooks")
                    .fontWeight(.medium)

                Spacer()

                Button(openCodeHooksInstalled ? "Reinstall" : "Install") { installOpenCodeHooks() }
                    .disabled(!cliInstalled)
                if openCodeHooksInstalled {
                    Button("Uninstall") { uninstallOpenCodeHooks() }
                }
            }

            // 4. Daemon
            HStack(spacing: 8) {
                Image(systemName: daemonRunning ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(daemonRunning ? .green : .secondary)
                    .frame(width: 20)

                Text("Daemon")
                    .fontWeight(.medium)

                Spacer()

                if daemonRunning {
                    Text("Running")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Button("Start") { startDaemon() }
                        .disabled(!cliInstalled)
                }
            }

            if let installError {
                Text(installError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let cliUpdateMessage {
                Text(cliUpdateMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Usage

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Getting Started")
                .font(.headline)

            Text("Launch a tracked Claude agent with:")
                .foregroundStyle(.secondary)

            Text("agenthub run")
                .font(.system(.body, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .textSelection(.enabled)

            Text("The agent will appear in the sidebar and you can monitor its progress in the embedded terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func checkStatus() {
        hasBun = HookInstaller.isCommandAvailable("bun")
        hasClaude = HookInstaller.isCommandAvailable("claude")
        cliInstalled = HookInstaller.findBinary() != nil
        daemonRunning = HookInstaller.isDaemonRunning()

        switch HookInstaller.cliVersionStatus() {
        case .needsUpdate(let installedVersion, let expectedVersion):
            cliNeedsUpdate = true
            if let installedVersion {
                cliUpdateMessage = "CLI update available: installed \(installedVersion), expected \(expectedVersion)"
            } else {
                cliUpdateMessage = "CLI update available: installed version unknown, expected \(expectedVersion)"
            }
        case .upToDate:
            cliNeedsUpdate = false
            cliUpdateMessage = nil
        case .notInstalled:
            cliNeedsUpdate = false
            cliUpdateMessage = nil
        }
        claudeHooksInstalled = HookInstaller.isClaudeHooksInstalled()
        openCodeHooksInstalled = HookInstaller.isOpenCodeHooksInstalled()
    }

    private func installCLI() {
        installError = nil
        cliUpdateMessage = nil
        guard let source = HookInstaller.findBinary() ?? (hasBun ? "" : nil) else {
            installError = "bun is required to install the CLI"
            return
        }
        do {
            _ = try HookInstaller.installBinary(from: source)
            cliInstalled = true
            cliNeedsUpdate = false
        } catch {
            installError = error.localizedDescription
        }
    }

    private func installClaudeHooks() {
        installError = nil
        let result = HookInstaller.installClaude(binaryPath: "")
        if result.exitCode != 0 {
            installError = result.stderr.isEmpty ? "Failed to install Claude hooks" : result.stderr
        }
        claudeHooksInstalled = HookInstaller.isClaudeHooksInstalled()
    }

    private func installOpenCodeHooks() {
        installError = nil
        let result = HookInstaller.installOpenCode(binaryPath: "")
        if result.exitCode != 0 {
            installError = result.stderr.isEmpty ? "Failed to install OpenCode hooks" : result.stderr
        }
        openCodeHooksInstalled = HookInstaller.isOpenCodeHooksInstalled()
    }

    private func uninstallClaudeHooks() {
        installError = nil
        let result = HookInstaller.uninstallClaude()
        if result.exitCode != 0 {
            installError = result.stderr.isEmpty ? "Failed to uninstall Claude hooks" : result.stderr
        }
        claudeHooksInstalled = HookInstaller.isClaudeHooksInstalled()
    }

    private func uninstallOpenCodeHooks() {
        installError = nil
        let result = HookInstaller.uninstallOpenCode()
        if result.exitCode != 0 {
            installError = result.stderr.isEmpty ? "Failed to uninstall OpenCode hooks" : result.stderr
        }
        openCodeHooksInstalled = HookInstaller.isOpenCodeHooksInstalled()
    }

    private func startDaemon() {
        installError = nil
        let result = HookInstaller.startDaemon()
        if result.exitCode != 0 {
            installError = result.stderr.isEmpty ? "Failed to start daemon" : result.stderr
        }
        // Give daemon a moment to write its PID file
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            daemonRunning = HookInstaller.isDaemonRunning()
        }
    }
}
