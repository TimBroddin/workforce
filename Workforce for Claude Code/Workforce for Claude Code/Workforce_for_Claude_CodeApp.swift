import SwiftUI

@main
struct Workforce_for_Claude_CodeApp: App {
    @State private var agentStore = AgentStore()
    @State private var socketServer: SocketServer?

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: agentStore)
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
        .menuBarExtraStyle(.window)
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
