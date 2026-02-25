# Connected Clients Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show which remote Workforce apps are polling your local HTTP server, displayed as a "Connected Clients" section at the bottom of the Remote tab.

**Architecture:** Remote Workforce apps register via `POST /api/clients/register` through their SSH tunnel on every poll cycle. The local HTTPServer tracks clients in an in-memory dictionary, pruning stale entries after 30s. A new `ClientRegistry` observable object exposes connected clients to the UI.

**Tech Stack:** Swift, SwiftUI, NWListener HTTP server, @Observable

---

### Task 1: Create ConnectedClient Model

**Files:**
- Create: `Workforce/Workforce/Models/ConnectedClient.swift`

**Step 1: Create the ConnectedClient model**

```swift
import Foundation

struct ConnectedClient: Codable, Identifiable {
    let clientId: String
    let hostname: String
    let user: String
    var lastSeen: Date

    var id: String { clientId }

    var displayName: String {
        "\(user)@\(hostname)"
    }
}
```

**Step 2: Commit**

```bash
git add Workforce/Workforce/Models/ConnectedClient.swift
git commit -m "feat: add ConnectedClient model"
```

---

### Task 2: Create ClientRegistry Observable

**Files:**
- Create: `Workforce/Workforce/Services/ClientRegistry.swift`

**Step 1: Create the ClientRegistry**

This is the in-memory store for connected clients, observable by SwiftUI. Handles registration, lookup, and pruning.

```swift
import Foundation
import Observation

@Observable
final class ClientRegistry {
    private(set) var clients: [String: ConnectedClient] = [:]
    private var pruneTimer: Timer?
    private let staleThreshold: TimeInterval = 30

    var connectedClients: [ConnectedClient] {
        Array(clients.values).sorted { $0.hostname < $1.hostname }
    }

    func register(clientId: String, hostname: String, user: String) {
        clients[clientId] = ConnectedClient(
            clientId: clientId,
            hostname: hostname,
            user: user,
            lastSeen: Date()
        )
    }

    func startPruning() {
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.pruneStaleClients()
        }
    }

    func stopPruning() {
        pruneTimer?.invalidate()
        pruneTimer = nil
    }

    private func pruneStaleClients() {
        let cutoff = Date().addingTimeInterval(-staleThreshold)
        clients = clients.filter { $0.value.lastSeen > cutoff }
    }
}
```

**Step 2: Commit**

```bash
git add Workforce/Workforce/Services/ClientRegistry.swift
git commit -m "feat: add ClientRegistry for tracking connected clients"
```

---

### Task 3: Add Client Endpoints to HTTPServer

**Files:**
- Modify: `Workforce/Workforce/Services/HTTPServer.swift`

**Step 1: Add clientRegistry property to HTTPServer**

In `HTTPServer.swift`, add a `clientRegistry` property to the class:

```swift
final class HTTPServer {
    private var listener: NWListener?
    private let store: AgentStore
    private let eventLog: EventLog
    let clientRegistry: ClientRegistry  // ADD THIS
    private let portFilePath: String
    private let encoder: JSONEncoder
```

Update the `init`:

```swift
init(store: AgentStore, eventLog: EventLog, clientRegistry: ClientRegistry) {
    self.store = store
    self.eventLog = eventLog
    self.clientRegistry = clientRegistry
    self.portFilePath = "/tmp/workforce-\(getuid()).port"
    // ... rest unchanged
}
```

**Step 2: Add routing for client endpoints**

In `processRequest`, add two new cases to the switch:

```swift
case ("POST", "/api/clients/register"):
    handleRegisterClient(body: body, on: connection)
case ("GET", "/api/clients"):
    handleGetClients(on: connection)
```

Add them before the `("OPTIONS", _)` case.

**Step 3: Implement the handlers**

Add after the existing `handlePostEvent` method:

```swift
private func handleRegisterClient(body: Data, on connection: NWConnection) {
    struct RegisterRequest: Decodable {
        let clientId: String
        let hostname: String
        let user: String
    }

    let decoder = JSONDecoder()
    guard let request = try? decoder.decode(RegisterRequest.self, from: body) else {
        sendResponse(on: connection, status: "400 Bad Request", body: #"{"error":"invalid body"}"#)
        return
    }

    clientRegistry.register(clientId: request.clientId, hostname: request.hostname, user: request.user)
    sendResponse(on: connection, status: "200 OK", body: #"{"ok":true}"#)
}

private func handleGetClients(on connection: NWConnection) {
    do {
        let data = try encoder.encode(clientRegistry.connectedClients)
        let body = String(data: data, encoding: .utf8) ?? "[]"
        sendResponse(on: connection, status: "200 OK", body: body)
    } catch {
        sendResponse(on: connection, status: "500 Internal Server Error", body: #"{"error":"encoding failed"}"#)
    }
}
```

**Step 4: Commit**

```bash
git add Workforce/Workforce/Services/HTTPServer.swift
git commit -m "feat: add client registration and listing endpoints to HTTPServer"
```

---

### Task 4: Wire ClientRegistry into App Lifecycle

**Files:**
- Modify: `Workforce/Workforce/WorkforceApp.swift`

**Step 1: Add ClientRegistry to WorkforceApp**

Add a `@State private var clientRegistry = ClientRegistry()` property.

Update the HTTPServer init call to pass it:

```swift
let http = HTTPServer(store: store, eventLog: log, clientRegistry: registry)
```

Create the registry before the HTTPServer:

```swift
let registry = ClientRegistry()
registry.startPruning()
_clientRegistry = State(initialValue: registry)
```

Pass it to `MainWindowView`:

```swift
MainWindowView(store: agentStore, eventLog: eventLog, remoteHostManager: remoteHostManager!, clientRegistry: clientRegistry)
```

Add cleanup in the `willTerminateNotification` handler:

```swift
registry.stopPruning()
```

**Step 2: Commit**

```bash
git add Workforce/Workforce/WorkforceApp.swift
git commit -m "feat: wire ClientRegistry into app lifecycle"
```

---

### Task 5: Add Client Registration to RemoteHostManager

**Files:**
- Modify: `Workforce/Workforce/Services/RemoteHostManager.swift`

**Step 1: Add registerClient call alongside pollAgents**

Add a new method `registerWithRemote` that sends `POST /api/clients/register` through the tunnel:

```swift
func registerWithRemote(hostId: UUID) {
    guard let conn = connections[hostId], conn.status == .connected, conn.localPort > 0 else { return }
    guard let url = URL(string: "http://localhost:\(conn.localPort)/api/clients/register") else { return }

    let clientId = Self.stableClientId
    let hostname = Host.current().localizedName ?? "unknown"
    let user = NSUserName()

    let body: [String: String] = [
        "clientId": clientId,
        "hostname": hostname,
        "user": user
    ]

    guard let bodyData = try? JSONEncoder().encode(body) else { return }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = bodyData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 5

    URLSession.shared.dataTask(with: request).resume()
}

private static let stableClientId: String = {
    let key = "workforceClientId"
    if let existing = UserDefaults.standard.string(forKey: key) {
        return existing
    }
    let newId = UUID().uuidString
    UserDefaults.standard.set(newId, forKey: key)
    return newId
}()
```

**Step 2: Call registerWithRemote from pollAgents**

At the end of `pollAgents(hostId:)`, after the `URLSession.shared.dataTask` call, add:

```swift
registerWithRemote(hostId: hostId)
```

This piggybacks the registration/heartbeat on the existing 5-second poll cycle.

**Step 3: Commit**

```bash
git add Workforce/Workforce/Services/RemoteHostManager.swift
git commit -m "feat: register client with remote server on each poll cycle"
```

---

### Task 6: Add Connected Clients Section to Remote Tab UI

**Files:**
- Modify: `Workforce/Workforce/Views/MainWindowView.swift`

**Step 1: Add clientRegistry property to MainWindowView**

Add to the struct properties:

```swift
let clientRegistry: ClientRegistry
```

**Step 2: Add the connected clients section at the bottom of remoteSidebarContent**

After the existing `ForEach(enabledRemoteHosts)` block (and its closing brace), add the connected clients section. It should appear at the bottom, only when there are connected clients:

```swift
// Connected clients section
let connectedClients = clientRegistry.connectedClients
if !connectedClients.isEmpty {
    Spacer().frame(height: 16)

    HStack(spacing: 6) {
        Image(systemName: "person.2.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
        Text("Connected Clients")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
        Spacer()
        Text("\(connectedClients.count)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

    ForEach(connectedClients) { client in
        HStack(spacing: 6) {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
            Text(client.displayName)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
```

**Step 3: Commit**

```bash
git add Workforce/Workforce/Views/MainWindowView.swift
git commit -m "feat: add Connected Clients section to Remote tab sidebar"
```

---

### Task 7: Build and Verify

**Step 1: Build the project**

Run: `xcodebuild -project Workforce/Workforce.xcodeproj -scheme Workforce build`

Expected: Build succeeds

**Step 2: Fix any compilation errors**

Address any issues from the build.

**Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: resolve compilation issues for connected clients feature"
```
