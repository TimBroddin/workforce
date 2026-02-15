import SwiftUI

struct SetupWizardView: View {
    @Binding var isPresented: Bool
    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false

    // Prereq status
    @State private var hasTmux = false
    @State private var hasClaude = false

    // Install status
    @State private var cliInstalled = false
    @State private var installedPath: String?
    @State private var hooksInstalled = false
    @State private var installError: String?

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
        .frame(width: 520, height: 580)
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

            Text("Welcome to Workforce")
                .font(.title)
                .fontWeight(.bold)

            Text("Workforce monitors your Claude Code sessions in real-time. It tracks agents, subagents, tool usage, and notifications — all in one window.")
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
                name: "tmux",
                installed: hasTmux,
                hint: "brew install tmux"
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

            HStack(spacing: 8) {
                Image(systemName: cliInstalled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(cliInstalled ? .green : .secondary)
                    .frame(width: 20)

                Text("Workforce CLI")
                    .fontWeight(.medium)

                Spacer()

                if !cliInstalled {
                    Button("Install") { installCLI() }
                        .disabled(HookInstaller.findBinary() == nil)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: hooksInstalled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(hooksInstalled ? .green : .secondary)
                    .frame(width: 20)

                Text("Claude Code Hooks")
                    .fontWeight(.medium)

                Spacer()

                if !hooksInstalled {
                    Button("Install") { installHooks() }
                        .disabled(!cliInstalled)
                }
            }

            if let installError {
                Text(installError)
                    .font(.caption)
                    .foregroundStyle(.red)
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

            Text("workforce run")
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
        hasTmux = HookInstaller.isCommandAvailable("tmux")
        hasClaude = HookInstaller.isCommandAvailable("claude")
        let path = "/usr/local/bin/workforce"
        cliInstalled = FileManager.default.isExecutableFile(atPath: path)
        if cliInstalled { installedPath = path }
        hooksInstalled = HookInstaller.isInstalled()
    }

    private func installCLI() {
        installError = nil
        guard let source = HookInstaller.findBinary() else {
            installError = "workforce binary not found in build output"
            return
        }
        do {
            installedPath = try HookInstaller.installBinary(from: source)
            cliInstalled = true
        } catch {
            installError = error.localizedDescription
        }
    }

    private func installHooks() {
        installError = nil
        guard let path = installedPath else { return }
        do {
            _ = try HookInstaller.install(binaryPath: path)
            hooksInstalled = true
        } catch {
            installError = error.localizedDescription
        }
    }
}
