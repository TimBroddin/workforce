import SwiftUI

struct HookStatusView: View {
    @State private var hooksInstalled = HookInstaller.isInstalled()
    @State private var message: String?

    var body: some View {
        HStack(spacing: 6) {
            if let message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if hooksInstalled {
                Button("Uninstall Hooks") { uninstall() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Install Hooks") { install() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }

    private func install() {
        let claudeResult = HookInstaller.installClaude(binaryPath: "")
        let openCodeResult = HookInstaller.installOpenCode(binaryPath: "")

        if claudeResult.exitCode == 0 && openCodeResult.exitCode == 0 {
            hooksInstalled = true
            message = "Hooks installed."
        } else {
            let err = [claudeResult, openCodeResult]
                .filter { $0.exitCode != 0 }
                .map(\.stderr)
                .joined(separator: "; ")
            message = err.isEmpty ? "Install failed." : "Install failed: \(err)"
        }
        clearMessage()
    }

    private func uninstall() {
        let claudeResult = HookInstaller.uninstallClaude()
        let openCodeResult = HookInstaller.uninstallOpenCode()

        if claudeResult.exitCode == 0 && openCodeResult.exitCode == 0 {
            hooksInstalled = false
            message = "Hooks removed."
        } else {
            let err = [claudeResult, openCodeResult]
                .filter { $0.exitCode != 0 }
                .map(\.stderr)
                .joined(separator: "; ")
            message = err.isEmpty ? "Uninstall failed." : "Uninstall failed: \(err)"
        }
        clearMessage()
    }

    private func clearMessage() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            message = nil
        }
    }
}
