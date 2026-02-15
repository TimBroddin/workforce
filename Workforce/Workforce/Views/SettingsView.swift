import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultTerminal") private var defaultTerminal: String = SupportedTerminal.terminal.rawValue
    @AppStorage("defaultIDE") private var defaultIDE: String = SupportedIDE.vscode.rawValue

    @State private var cliInstalled = false
    @State private var hooksInstalled = false
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
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Reinstall") { installCLI() }
                            .disabled(HookInstaller.findBinary() == nil)
                    } else {
                        Button("Install") { installCLI() }
                            .disabled(HookInstaller.findBinary() == nil)
                    }
                }

                HStack {
                    Text("Claude Code Hooks")
                    Spacer()
                    if hooksInstalled {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Reinstall") { installHooks() }
                    } else {
                        Button("Install") { installHooks() }
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
        .frame(width: 350)
        .task { checkStatus() }
    }

    private func checkStatus() {
        cliInstalled = FileManager.default.isExecutableFile(atPath: "/usr/local/bin/workforce")
        hooksInstalled = HookInstaller.isInstalled()
    }

    private func installCLI() {
        guard let source = HookInstaller.findBinary() else {
            message = "workforce binary not found"
            return
        }
        do {
            _ = try HookInstaller.installBinary(from: source)
            cliInstalled = true
            message = "CLI installed to /usr/local/bin/workforce"
        } catch {
            message = "Install failed: \(error.localizedDescription)"
        }
    }

    private func installHooks() {
        do {
            let count = try HookInstaller.install(binaryPath: "/usr/local/bin/workforce")
            hooksInstalled = true
            message = count > 0 ? "Installed \(count) hooks." : "Hooks already installed."
        } catch {
            message = "Install failed: \(error.localizedDescription)"
        }
    }
}
