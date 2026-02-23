# HTTP API Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace Unix domain socket IPC with HTTP POST endpoints so all CLI-to-app communication goes through the HTTP API.

**Architecture:** The existing `HTTPServer` gains POST endpoint support and body parsing. The CLI's `APIClient` gains a `post()` method. All hook commands switch from `SocketClient.send()` to `APIClient.post()`. Socket code is deleted.

**Tech Stack:** Swift, Network framework (NWListener), ArgumentParser, Foundation

---

### Task 1: Add POST body parsing and /api/events endpoint to HTTPServer

**Files:**
- Modify: `Workforce/Workforce/Services/HTTPServer.swift`

**Step 1: Update HTTPServer to accept EventLog**

Add `eventLog` property to `HTTPServer`:

```swift
private let eventLog: EventLog

init(store: AgentStore, eventLog: EventLog) {
    self.store = store
    self.eventLog = eventLog
    // ... rest unchanged
}
```

**Step 2: Allow POST method and route to handler**

In `processRequest`, remove the GET-only guard. Update routing:

```swift
private func processRequest(_ headerData: Data, body: Data, on connection: NWConnection) {
    guard let requestLine = parseRequestLine(from: headerData) else {
        sendResponse(on: connection, status: "400 Bad Request", body: #"{"error":"bad request"}"#)
        return
    }

    let method = requestLine.method
    let path = requestLine.path

    switch (method, path) {
    case ("GET", "/api/agents"):
        handleGetAgents(on: connection)
    case ("GET", _) where path.hasPrefix("/api/agents/"):
        let id = String(path.dropFirst("/api/agents/".count))
        if id.isEmpty {
            handleGetAgents(on: connection)
        } else {
            handleGetAgent(id: id, on: connection)
        }
    case ("POST", "/api/events"):
        handlePostEvent(body: body, on: connection)
    case ("OPTIONS", _):
        sendResponse(on: connection, status: "204 No Content", body: "")
    default:
        sendResponse(on: connection, status: "404 Not Found", body: #"{"error":"not found"}"#)
    }
}
```

**Step 3: Implement body reading**

Update `receiveRequest` to parse Content-Length from headers and read the full body before calling `processRequest`. The existing code reads until `\r\n\r\n` — after that, read `Content-Length` more bytes for the body:

```swift
private func receiveRequest(on connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
        [weak self] content, _, isComplete, error in
        guard let self else { return }

        var buffer = accumulated
        if let content { buffer.append(content) }

        if let headerEnd = self.findHeaderEnd(in: buffer) {
            let headerData = Data(buffer[buffer.startIndex..<headerEnd])
            let remaining = Data(buffer[headerEnd...])
            let contentLength = self.parseContentLength(from: headerData)

            if contentLength > 0, remaining.count < contentLength, !isComplete {
                self.receiveBody(on: connection, headerData: headerData, accumulated: remaining, expected: contentLength)
            } else {
                self.processRequest(headerData, body: remaining, on: connection)
            }
        } else if isComplete || error != nil {
            if !buffer.isEmpty {
                self.processRequest(buffer, body: Data(), on: connection)
            } else {
                connection.cancel()
            }
        } else {
            self.receiveRequest(on: connection, accumulated: buffer)
        }
    }
}

private func receiveBody(on connection: NWConnection, headerData: Data, accumulated: Data, expected: Int) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
        [weak self] content, _, isComplete, error in
        guard let self else { return }

        var buffer = accumulated
        if let content { buffer.append(content) }

        if buffer.count >= expected || isComplete || error != nil {
            self.processRequest(headerData, body: buffer, on: connection)
        } else {
            self.receiveBody(on: connection, headerData: headerData, accumulated: buffer, expected: expected)
        }
    }
}

private func parseContentLength(from headerData: Data) -> Int {
    guard let headerString = String(data: headerData, encoding: .utf8) else { return 0 }
    for line in headerString.split(separator: "\r\n") {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count == 2,
           parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length",
           let length = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
            return length
        }
    }
    return 0
}
```

**Step 4: Implement handlePostEvent**

```swift
private func handlePostEvent(body: Data, on connection: NWConnection) {
    let raw = String(data: body, encoding: .utf8) ?? "<invalid utf8>"
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
        let message = try decoder.decode(SocketMessage.self, from: body)
        NSLog("[Workforce] HTTP event: type=%@ session=%@", message.type.rawValue, message.sessionId)
        eventLog.append(message: message, rawJSON: raw)
        store.handleMessage(message)
        sendResponse(on: connection, status: "200 OK", body: #"{"ok":true}"#)
    } catch {
        NSLog("[Workforce] HTTP event decode error: %@", error.localizedDescription)
        eventLog.append(message: nil, rawJSON: raw, error: error.localizedDescription)
        sendResponse(on: connection, status: "400 Bad Request", body: #"{"error":"invalid message"}"#)
    }
}
```

**Step 5: Add CORS headers to sendResponse**

```swift
private func sendResponse(on connection: NWConnection, status: String, body: String) {
    let response = [
        "HTTP/1.1 \(status)",
        "Content-Type: application/json",
        "Content-Length: \(body.utf8.count)",
        "Access-Control-Allow-Origin: *",
        "Access-Control-Allow-Methods: GET, POST, OPTIONS",
        "Access-Control-Allow-Headers: Content-Type",
        "Connection: close",
        "",
        body,
    ].joined(separator: "\r\n")
    // ... rest unchanged
}
```

**Step 6: Commit**

```
feat: add POST /api/events endpoint to HTTPServer
```

---

### Task 2: Add configurable bind address

**Files:**
- Modify: `Workforce/Workforce/Services/HTTPServer.swift`
- Modify: `Workforce/Workforce/Views/SettingsView.swift`

**Step 1: Accept listenOnAllInterfaces parameter in HTTPServer**

Update `start()` to accept a boolean:

```swift
func start(listenOnAllInterfaces: Bool = false) throws {
    let params = NWParameters.tcp
    if listenOnAllInterfaces {
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .any, port: .any)
    } else {
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
    }
    // ... rest unchanged
}
```

**Step 2: Add toggle in SettingsView**

Add after the "Notification Summaries" section:

```swift
Section("Network") {
    Toggle("Listen on all interfaces", isOn: $listenOnAllInterfaces)
    Text("When enabled, the API is accessible from other devices on your network.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

With the `@AppStorage` property:

```swift
@AppStorage("listenOnAllInterfaces") private var listenOnAllInterfaces: Bool = false
```

**Step 3: Update WorkforceApp to pass setting to HTTPServer**

This will be done in Task 4 when we update WorkforceApp.

**Step 4: Commit**

```
feat: add configurable bind address for HTTP server
```

---

### Task 3: Add APIClient.post() to CLI

**Files:**
- Modify: `WorkforceKit/Sources/WorkforceCLI/APIClient.swift`

**Step 1: Add post method**

```swift
static func post(_ message: SocketMessage) {
    guard let port = readPort() else { return }
    guard let url = URL(string: "http://localhost:\(port)/api/events") else { return }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 2

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let body = try? encoder.encode(message) else { return }
    request.httpBody = body

    let semaphore = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: request) { _, _, _ in
        semaphore.signal()
    }
    task.resume()
    semaphore.wait()
}
```

**Step 2: Commit**

```
feat: add APIClient.post() for sending events via HTTP
```

---

### Task 4: Switch all hook commands from SocketClient to APIClient

**Files:**
- Modify: `WorkforceKit/Sources/WorkforceCLI/Commands/RunCommand.swift:49` — `SocketClient.send(message)` → `APIClient.post(message)`
- Modify: `WorkforceKit/Sources/WorkforceCLI/Commands/SessionStartCommand.swift:14` — `SocketClient.send(...)` → `APIClient.post(...)`
- Modify: `WorkforceKit/Sources/WorkforceCLI/Commands/ToolUseCommand.swift:14,33,52` — all three `SocketClient.send(...)` → `APIClient.post(...)`
- Modify: `WorkforceKit/Sources/WorkforceCLI/Commands/NotificationCommand.swift:17` — `SocketClient.send(...)` → `APIClient.post(...)`
- Modify: `WorkforceKit/Sources/WorkforceCLI/Commands/SubagentCommand.swift:14,33` — both `SocketClient.send(...)` → `APIClient.post(...)`
- Modify: `WorkforceKit/Sources/WorkforceCLI/Commands/StopCommand.swift:16,26` — both `SocketClient.send(...)` → `APIClient.post(...)`
- Modify: `WorkforceKit/Sources/WorkforceCLI/Commands/SessionEndCommand.swift:19,31` — both `SocketClient.send(...)` → `APIClient.post(...)`

**Step 1: Find-and-replace `SocketClient.send` → `APIClient.post` in all command files**

Every `SocketClient.send(` becomes `APIClient.post(` — the argument (a `SocketMessage`) is identical.

**Step 2: Commit**

```
refactor: switch all hook commands from socket to HTTP API
```

---

### Task 5: Remove SocketServer and SocketClient

**Files:**
- Delete: `Workforce/Workforce/Services/SocketServer.swift`
- Delete: `WorkforceKit/Sources/WorkforceCLI/SocketClient.swift`
- Modify: `Workforce/Workforce/WorkforceApp.swift`

**Step 1: Update WorkforceApp.swift**

Remove `SocketServer` state and initialization. Pass `eventLog` to `HTTPServer`. Read bind setting:

```swift
@main
struct WorkforceApp: App {
    @State private var agentStore = AgentStore()
    @State private var eventLog = EventLog()
    @State private var httpServer: HTTPServer?
    @Environment(\.openWindow) private var openWindow

    // ... body unchanged ...

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

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            http.stop()
        }

        NotificationManager.shared.requestPermission()
    }
}
```

**Step 2: Delete SocketServer.swift**

Remove `Workforce/Workforce/Services/SocketServer.swift`.

**Step 3: Delete SocketClient.swift**

Remove `WorkforceKit/Sources/WorkforceCLI/SocketClient.swift`.

**Step 4: Commit**

```
refactor: remove SocketServer and SocketClient, HTTP-only IPC
```

---

### Task 6: Build and verify

**Step 1: Build the CLI**

```bash
cd WorkforceKit && swift build
```

Expected: builds cleanly with no SocketClient references.

**Step 2: Build the app**

Build in Xcode or via `xcodebuild`. Verify no SocketServer references.

**Step 3: Manual test**

1. Run the app
2. Check that `GET /api/agents` still works: `curl http://localhost:$(cat /tmp/workforce-$(id -u).port)/api/agents`
3. Test POST: `curl -X POST http://localhost:$(cat /tmp/workforce-$(id -u).port)/api/events -H 'Content-Type: application/json' -d '{"type":"register","sessionId":"test-123","cwd":"/tmp","timestamp":"2026-02-22T00:00:00Z","name":"Test Agent","avatarSeed":"test","status":"idle","agentType":"claude"}'`
4. Verify agent appears in `GET /api/agents`
5. Run `workforce run` and verify hooks register via HTTP

**Step 4: Commit**

```
chore: verify HTTP API migration works end-to-end
```
