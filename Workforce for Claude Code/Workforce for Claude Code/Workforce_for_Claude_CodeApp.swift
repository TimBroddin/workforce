import SwiftUI

@main
struct Workforce_for_Claude_CodeApp: App {
    @State private var agentStore = AgentStore()
    @State private var socketServer: SocketServer?

    var body: some Scene {
        Window("Workforce", id: "main") {
            MainWindowView(store: agentStore)
        }

        MenuBarExtra {
            Button("Show Workforce") {
                NSApp.activate()
                for window in NSApp.windows where window.identifier?.rawValue == "main" {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            Divider()
            Text("\(agentStore.agents.count) agent\(agentStore.agents.count == 1 ? "" : "s")")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            let hasPermission = agentStore.agents.values.contains { $0.status == .waitingForPermission }
            let hasWaiting = agentStore.agents.values.contains { $0.status == .waitingForInput }

            if hasPermission {
                Image(systemName: "person.3.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red, .primary)
            } else if hasWaiting {
                Image(systemName: "person.3.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.orange, .primary)
            } else {
                Image(systemName: "person.3.fill")
            }
        }
    }

    init() {
        let store = AgentStore()
        _agentStore = State(initialValue: store)
        let server = SocketServer(store: store)
        _socketServer = State(initialValue: server)
        try? server.start()
        NotificationManager.shared.requestPermission()
    }
}
