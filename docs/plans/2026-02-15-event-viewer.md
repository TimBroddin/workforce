# Event Viewer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a separate window that shows all incoming socket messages in real time for debugging and activity monitoring.

**Architecture:** New `EventLog` observable service captures every socket message (with raw JSON) as it arrives. A new `EventViewerWindow` displays them in a filterable list. The `SocketServer` passes messages to both `EventLog` and `AgentStore`.

**Tech Stack:** SwiftUI, macOS `@Observable`, existing `SocketMessage` model.

**Design doc:** `docs/plans/2026-02-15-event-viewer-design.md`

---

### Task 1: Create EventLog Service

**Files:**
- Create: `Workforce for Claude Code/Workforce for Claude Code/Services/EventLog.swift`

**Step 1: Create the EventLog service**

```swift
import Foundation

struct EventLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: SocketMessage?
    let rawJSON: String
    let error: String?
}

@Observable
final class EventLog {
    private(set) var entries: [EventLogEntry] = []
    private let maxEntries = 1000

    func append(message: SocketMessage?, rawJSON: String, error: String? = nil) {
        let entry = EventLogEntry(
            timestamp: Date(),
            message: message,
            rawJSON: rawJSON,
            error: error
        )
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
```

**Step 2: Add to Xcode project**

Add `EventLog.swift` to the Xcode project target in the Services group.

**Step 3: Commit**

```bash
git add "Workforce for Claude Code/Workforce for Claude Code/Services/EventLog.swift"
git commit -m "feat: add EventLog service for capturing socket messages"
```

---

### Task 2: Wire EventLog into SocketServer

**Files:**
- Modify: `Workforce for Claude Code/Workforce for Claude Code/Services/SocketServer.swift`

**Step 1: Add eventLog property to SocketServer**

At line 6 of `SocketServer.swift`, add a second stored property:

```swift
final class SocketServer {
    private var listener: NWListener?
    private let store: AgentStore
    private let eventLog: EventLog
    private let socketPath: String
```

**Step 2: Update init to accept EventLog**

Change the `init` at line 9:

```swift
    init(store: AgentStore, eventLog: EventLog) {
        self.store = store
        self.eventLog = eventLog
        self.socketPath = "/tmp/workforce-\(getuid()).sock"
    }
```

**Step 3: Update processMessage to log events**

Replace the `processMessage` method (lines 60-75) with:

```swift
    private func processMessage(_ data: Data) {
        let lines = data.split(separator: UInt8(ascii: "\n"))
        for line in lines {
            let raw = String(data: Data(line), encoding: .utf8) ?? "<invalid utf8>"
            NSLog("[Workforce] Received: %@", raw)
            do {
                let message = try JSONDecoder().decode(SocketMessage.self, from: Data(line))
                NSLog("[Workforce] Decoded: type=%@ session=%@ tmux=%@",
                      message.type.rawValue, message.sessionId, message.tmuxSession ?? "nil")
                eventLog.append(message: message, rawJSON: raw)
                store.handleMessage(message)
            } catch {
                NSLog("[Workforce] Decode error: %@", error.localizedDescription)
                eventLog.append(message: nil, rawJSON: raw, error: error.localizedDescription)
            }
        }
    }
```

**Step 4: Commit**

```bash
git add "Workforce for Claude Code/Workforce for Claude Code/Services/SocketServer.swift"
git commit -m "feat: wire EventLog into SocketServer to capture all messages"
```

---

### Task 3: Create EventViewerWindow View

**Files:**
- Create: `Workforce for Claude Code/Workforce for Claude Code/Views/EventViewerWindow.swift`

**Step 1: Create the view**

```swift
import SwiftUI

struct EventViewerWindow: View {
    let eventLog: EventLog
    @State private var selectedEntryId: UUID?
    @State private var typeFilter: SocketMessageType?

    private var filteredEntries: [EventLogEntry] {
        guard let filter = typeFilter else { return eventLog.entries }
        return eventLog.entries.filter { $0.message?.type == filter }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            eventList
            Divider()
            footer
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Picker("Filter", selection: $typeFilter) {
                Text("All Types").tag(nil as SocketMessageType?)
                Divider()
                ForEach(SocketMessageType.allCases, id: \.self) { type in
                    Label(type.rawValue, systemImage: "circle.fill")
                        .foregroundStyle(type.badgeColor)
                        .tag(type as SocketMessageType?)
                }
            }
            .frame(width: 180)

            Spacer()

            Button("Clear") {
                eventLog.clear()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Event List

    private var eventList: some View {
        ScrollViewReader { proxy in
            List(filteredEntries, selection: $selectedEntryId) { entry in
                eventRow(entry)
                    .id(entry.id)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
            .listStyle(.plain)
            .font(.system(.body, design: .monospaced))
            .onChange(of: eventLog.entries.count) {
                if let last = filteredEntries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func eventRow(_ entry: EventLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .foregroundStyle(.secondary)
                    .font(.system(.caption, design: .monospaced))

                if let message = entry.message {
                    Text(message.type.rawValue)
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(message.type.badgeColor.opacity(0.2))
                        .foregroundStyle(message.type.badgeColor)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Text(String(message.sessionId.prefix(8)))
                        .foregroundStyle(.secondary)
                        .font(.system(.caption, design: .monospaced))

                    Text(entrySummary(message))
                        .foregroundStyle(.primary)
                        .font(.caption)
                        .lineLimit(1)
                } else {
                    Text("ERROR")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.2))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    if let error = entry.error {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }

            if selectedEntryId == entry.id {
                Text(prettyJSON(entry.rawJSON))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func entrySummary(_ message: SocketMessage) -> String {
        switch message.type {
        case .register:
            return message.name ?? ""
        case .updateTool:
            return message.toolName ?? ""
        case .updateStatus:
            return message.status?.rawValue ?? ""
        case .notification:
            return message.notificationType ?? message.status?.rawValue ?? ""
        case .subagentStart, .subagentStop:
            return message.agentType ?? ""
        case .deregister:
            return ""
        }
    }

    private func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else {
            return raw
        }
        return str
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(filteredEntries.count) event\(filteredEntries.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
```

**Step 2: Add CaseIterable conformance and badge colors to SocketMessageType**

In `Workforce for Claude Code/Workforce for Claude Code/Models/SocketMessage.swift`, make `SocketMessageType` conform to `CaseIterable` and add a `badgeColor` computed property:

```swift
import SwiftUI

public enum SocketMessageType: String, Codable, Sendable, CaseIterable {
    case register
    case updateStatus
    case updateTool
    case notification
    case subagentStart
    case subagentStop
    case deregister

    var badgeColor: Color {
        switch self {
        case .register: .green
        case .deregister: .red
        case .updateTool: .blue
        case .updateStatus: .gray
        case .notification: .orange
        case .subagentStart: .purple
        case .subagentStop: .purple
        }
    }
}
```

Note: The `SocketMessage` model in the app target shadows the one in `WorkforceKit`. Only modify the app-level file at `Workforce for Claude Code/Workforce for Claude Code/Models/SocketMessage.swift`.

**Step 3: Add to Xcode project**

Add `EventViewerWindow.swift` to the Xcode project target in the Views group.

**Step 4: Commit**

```bash
git add "Workforce for Claude Code/Workforce for Claude Code/Views/EventViewerWindow.swift" \
        "Workforce for Claude Code/Workforce for Claude Code/Models/SocketMessage.swift"
git commit -m "feat: add EventViewerWindow view with filtering and JSON expansion"
```

---

### Task 4: Wire Everything Together in App Entry Point

**Files:**
- Modify: `Workforce for Claude Code/Workforce for Claude Code/Workforce_for_Claude_CodeApp.swift`

**Step 1: Add EventLog, second Window scene, and menu command**

Replace the full contents of `Workforce_for_Claude_CodeApp.swift`:

```swift
import SwiftUI

@main
struct Workforce_for_Claude_CodeApp: App {
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
        }

        Window("Event Viewer", id: "event-viewer") {
            EventViewerWindow(eventLog: eventLog)
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
```

**Step 2: Build and verify**

Build the project in Xcode (Cmd+B). The Event Viewer should be accessible from the Window menu.

**Step 3: Commit**

```bash
git add "Workforce for Claude Code/Workforce for Claude Code/Workforce_for_Claude_CodeApp.swift"
git commit -m "feat: add Event Viewer window with menu item (Cmd+Shift+E)"
```

---

### Task 5: Manual Testing

**Step 1: Launch the app and open Event Viewer**

- Build and run in Xcode
- Use Window > Event Viewer (or Cmd+Shift+E) to open the event viewer window

**Step 2: Trigger events**

From a terminal, run a claude session with workforce hooks installed. Verify:
- Events appear in real time in the event viewer
- Timestamps are correct
- Type badges show correct colors
- Clicking a row expands to show raw JSON
- Filter dropdown filters by message type
- Clear button clears all entries

**Step 3: Test decode errors**

Send malformed JSON to the socket to verify error entries appear:

```bash
echo '{"bad json' | nc -U /tmp/workforce-$(id -u).sock
```

Verify it shows as an ERROR row with the decode error message.
