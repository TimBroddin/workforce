import SwiftUI

@main
struct Workforce_for_Claude_CodeApp: App {
    @State private var agentStore = AgentStore()
    @State private var socketServer: SocketServer?
    @State private var statusItem: MenuBarStatusItem?

    var body: some Scene {
        Window("Workforce", id: "main") {
            MainWindowView(store: agentStore)
        }
    }

    init() {
        let store = AgentStore()
        _agentStore = State(initialValue: store)
        let server = SocketServer(store: store)
        _socketServer = State(initialValue: server)
        try? server.start()
        NotificationManager.shared.requestPermission()

        let item = MenuBarStatusItem(store: store)
        _statusItem = State(initialValue: item)
    }
}
