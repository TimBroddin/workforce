import SwiftUI

extension Notification.Name {
    static let showSetupWizard = Notification.Name("showSetupWizard")
}

@main
struct WorkforceApp: App {
    @State private var agentStore = AgentStore()
    @State private var eventLog = EventLog()
    @State private var socketServer: SocketServer?
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Workforce", id: "main") {
            MainWindowView(store: agentStore)
        }
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Event Viewer") {
                    openWindow(id: "event-viewer")
                }
                .keyboardShortcut("E", modifiers: [.command, .shift])
            }
            CommandGroup(after: .help) {
                Button("Setup Wizard...") {
                    NotificationCenter.default.post(name: .showSetupWizard, object: nil)
                }
            }
        }

        Window("Event Viewer", id: "event-viewer") {
            EventViewerWindow(eventLog: eventLog, store: agentStore)
        }

        Settings {
            SettingsView()
        }
    }

    init() {
        _ = NerdFontRegistration.registered

        let store = AgentStore()
        store.discoverTmuxSessions()
        _agentStore = State(initialValue: store)

        let log = EventLog()
        _eventLog = State(initialValue: log)

        let server = SocketServer(store: store, eventLog: log)
        _socketServer = State(initialValue: server)
        try? server.start()
        NotificationManager.shared.requestPermission()
    }
}
