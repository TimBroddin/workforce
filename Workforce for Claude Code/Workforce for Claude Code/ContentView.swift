import SwiftUI

struct ContentView: View {
    let store: AgentStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workforce")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

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
}
