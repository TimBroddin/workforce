import AppKit
import SwiftUI

extension Notification.Name {
    static let showSetupWizard = Notification.Name("showSetupWizard")
    static let terminalSendInput = Notification.Name("terminalSendInput")
}

@main
struct AgentHubApp: App {
    @State private var agentStore = AgentStore()
    @State private var eventLog = EventLog()
    @State private var remoteHostManager: RemoteHostManager
    @State private var daemonConnection = DaemonConnection()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("AgentHub", id: "main") {
            MainWindowView(store: agentStore, eventLog: eventLog, remoteHostManager: remoteHostManager, daemonConnection: daemonConnection)
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
            SettingsView(remoteHostManager: remoteHostManager)
        }
    }

    init() {
        _ = NerdFontRegistration.registered

        let store = AgentStore()
        store.load()
        _agentStore = State(initialValue: store)

        let log = EventLog()
        _eventLog = State(initialValue: log)

        let daemon = DaemonConnection()
        daemon.setStore(store)
        daemon.setEventLog(log)
        daemon.connect()
        _daemonConnection = State(initialValue: daemon)

        let remoteHosts = RemoteHostManager()
        remoteHosts.load()
        remoteHosts.connectAll()
        _remoteHostManager = State(initialValue: remoteHosts)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            daemon.disconnect()
            remoteHosts.disconnectAll()
        }

        NotificationManager.shared.requestPermission()
    }
}
