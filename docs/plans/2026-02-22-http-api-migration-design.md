# HTTP API Migration Design

## Goal

Replace the Unix domain socket IPC between the CLI and macOS app with HTTP POST endpoints on the existing HTTP server. Add a configurable bind address (localhost vs all interfaces) for remote access.

## Current State

- **SocketServer** listens on `/tmp/workforce-{uid}.sock` for newline-delimited JSON `SocketMessage` objects
- **HTTPServer** listens on `127.0.0.1:{random-port}`, serves `GET /api/agents` and `GET /api/agents/{id}`
- **SocketClient** (CLI) connects to the Unix socket, sends `SocketMessage` JSON + newline, waits for close
- **APIClient** (CLI) reads port from `/tmp/workforce-{uid}.port`, does HTTP GET for agent listing

## Changes

### 1. HTTPServer: Add POST /api/events

Accept `SocketMessage` JSON bodies. Parse request body, decode as `SocketMessage`, call `store.handleMessage()` and `eventLog.append()` — same logic currently in `SocketServer.processMessage()`.

- Parse Content-Length header to know how much body to read
- Read full body after headers
- Respond `200 OK` on success, `400 Bad Request` on decode failure
- HTTPServer needs a reference to `EventLog` (currently only SocketServer has this)

### 2. HTTPServer: Add CORS headers

Add `Access-Control-Allow-Origin: *` and related headers to all responses, for future web UI compatibility.

### 3. HTTPServer: Configurable bind address

- Add an `@AppStorage("listenOnAllInterfaces")` setting (default: false)
- When true, bind to `0.0.0.0` instead of `127.0.0.1`
- Expose this in SettingsView
- Restart listener when setting changes

### 4. CLI: Replace SocketClient with HTTP POST

- `APIClient.post(_ message: SocketMessage)` — POST to `http://localhost:{port}/api/events`
- All hook commands change from `SocketClient.send(message)` to `APIClient.post(message)`
- Same fire-and-forget semantics: silently fail if app isn't running

### 5. Remove SocketServer and SocketClient

- Delete `SocketServer.swift` from the app
- Delete `SocketClient.swift` from WorkforceKit CLI
- Remove socket file creation/cleanup
- Remove socket path references from WorkforceApp.swift

### 6. Update WorkforceApp.swift

- Remove SocketServer initialization
- Pass EventLog to HTTPServer
- Remove socket-related setup/teardown

## Files Modified

| File | Action |
|------|--------|
| `Workforce/Services/HTTPServer.swift` | Add POST handling, CORS, body parsing, configurable bind |
| `Workforce/Services/SocketServer.swift` | Delete |
| `Workforce/WorkforceApp.swift` | Remove SocketServer, pass EventLog to HTTPServer |
| `Workforce/Views/SettingsView.swift` | Add bind address toggle |
| `WorkforceKit/Sources/WorkforceCLI/APIClient.swift` | Add `post()` method |
| `WorkforceKit/Sources/WorkforceCLI/SocketClient.swift` | Delete |
| `WorkforceKit/Sources/WorkforceCLI/Commands/*.swift` | Replace `SocketClient.send()` with `APIClient.post()` |

## Message Format

No changes. The `SocketMessage` JSON format stays identical — only the transport changes from Unix socket to HTTP POST body.
