import SwiftUI

struct ContentView: View {
    let store: AgentStore
    @State private var hooksInstalled = HookInstaller.isInstalled()
    @State private var installMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workforce")
                    .font(.headline)
                Spacer()
                if hooksInstalled {
                    Button {
                        uninstallHooks()
                    } label: {
                        Label("Uninstall Hooks", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Button {
                        installHooks()
                    } label: {
                        Label("Install Hooks", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let installMessage {
                Text(installMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            Divider()

            if store.sortedAgents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.3.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No active agents")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Start a Claude Code session to see it here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.sortedAgents) { agent in
                            AgentRowView(agent: agent) {
                                WindowActivator.activate(agent)
                            }
                            Divider().padding(.horizontal, 8)
                        }
                    }
                }
                .frame(maxHeight: 400)
            }

            Divider()

            HStack {
                Text("\(store.agents.count) agent\(store.agents.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 380)
        .onReceive(NotificationCenter.default.publisher(for: .focusAgent)) { notification in
            if let sessionId = notification.userInfo?["sessionId"] as? String,
               let agent = store.agents[sessionId] {
                WindowActivator.activate(agent)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                store.pruneStale()
            }
        }
    }

    private func installHooks() {
        guard let binary = HookInstaller.findBinary() else {
            installMessage = "workforce binary not found. Build and copy to /usr/local/bin/workforce first."
            clearMessage()
            return
        }
        do {
            let count = try HookInstaller.install(binaryPath: binary)
            hooksInstalled = true
            installMessage = count > 0 ? "Installed \(count) hooks." : "Hooks already installed."
        } catch {
            installMessage = "Install failed: \(error.localizedDescription)"
        }
        clearMessage()
    }

    private func uninstallHooks() {
        do {
            let count = try HookInstaller.uninstall()
            hooksInstalled = false
            installMessage = "Removed \(count) hooks."
        } catch {
            installMessage = "Uninstall failed: \(error.localizedDescription)"
        }
        clearMessage()
    }

    private func clearMessage() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            installMessage = nil
        }
    }
}
