import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultTerminal") private var defaultTerminal: String = SupportedTerminal.terminal.rawValue
    @AppStorage("defaultIDE") private var defaultIDE: String = SupportedIDE.vscode.rawValue

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
        .frame(width: 350)
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
