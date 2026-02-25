import AppKit
import SwiftUI

extension Notification.Name {
    static let showSetupWizard = Notification.Name("showSetupWizard")
}

@main
struct WorkforceApp: App {
    @State private var agentStore = AgentStore()
    @State private var eventLog = EventLog()
    @State private var httpServer: HTTPServer?
    @State private var remoteHostManager: RemoteHostManager?
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Workforce", id: "main") {
            MainWindowView(store: agentStore, eventLog: eventLog, remoteHostManager: remoteHostManager!)
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
            SettingsView(remoteHostManager: remoteHostManager!)
        }
    }

    init() {
        _ = NerdFontRegistration.registered

        let store = AgentStore()
        store.load()
        store.discoverTmuxSessions()
        _agentStore = State(initialValue: store)

        let log = EventLog()
        _eventLog = State(initialValue: log)

        let listenOnAll = UserDefaults.standard.bool(forKey: "listenOnAllInterfaces")
        let http = HTTPServer(store: store, eventLog: log)
        _httpServer = State(initialValue: http)
        try? http.start(listenOnAllInterfaces: listenOnAll)

        let remoteHosts = RemoteHostManager()
        remoteHosts.load()
        remoteHosts.connectAll()
        _remoteHostManager = State(initialValue: remoteHosts)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            http.stop()
            remoteHosts.disconnectAll()
        }

        NotificationManager.shared.requestPermission()
    }
}
