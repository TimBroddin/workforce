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
        guard let binary = HookInstaller.findBinary() else {
            message = "workforce binary not found"
            clearMessage()
            return
        }
        do {
            let count = try HookInstaller.install(binaryPath: binary)
            hooksInstalled = true
            message = count > 0 ? "Installed \(count) hooks." : "Hooks already installed."
        } catch {
            message = "Install failed: \(error.localizedDescription)"
        }
        clearMessage()
    }

    private func uninstall() {
        do {
            let count = try HookInstaller.uninstall()
            hooksInstalled = false
            message = "Removed \(count) hooks."
        } catch {
            message = "Uninstall failed: \(error.localizedDescription)"
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
