# Connected Clients in Remote Tab

## Summary

Show which remote Workforce apps are polling your local server via SSH tunnel, displayed as a "Connected Clients" section at the bottom of the Remote tab.

## Architecture

### Client Registration Endpoint

Remote Workforce apps register with the local server via `POST /api/clients/register` through their SSH tunnel. The payload:

```json
{
  "clientId": "stable-uuid",
  "hostname": "tims-macbook.local",
  "user": "tim"
}
```

The server stores `{ clientId, hostname, user, lastSeen }` in an in-memory dictionary. Clients re-register on every poll cycle (every 5 seconds) as a heartbeat. Clients not seen for 30 seconds are pruned.

### API Endpoints

- `POST /api/clients/register` — Register/heartbeat a connected client
- `GET /api/clients` — Return list of connected clients (for potential external use)

### ConnectedClient Model

```swift
struct ConnectedClient: Codable, Identifiable {
    let clientId: String
    let hostname: String
    let user: String
    var lastSeen: Date
    var id: String { clientId }
}
```

### Data Flow

```
Remote Workforce App                    Your Local Workforce App
┌──────────────────────┐               ┌──────────────────────────┐
│ RemoteHostManager    │  SSH tunnel   │ HTTPServer               │
│  pollAgents()  ──────┼──────────────►│  GET /api/agents         │
│  registerClient() ───┼──────────────►│  POST /api/clients/reg.  │
│  (every 5s)          │               │                          │
└──────────────────────┘               │ connectedClients: [...]  │
                                       │  - prune after 30s       │
                                       └──────────┬───────────────┘
                                                  │ @Observable
                                       ┌──────────▼───────────────┐
                                       │ MainWindowView (Remote)  │
                                       │  Remote Hosts...         │
                                       │  Connected Clients (2)   │
                                       │   🟢 tim@macbook.local   │
                                       └──────────────────────────┘
```

## UI

"Connected Clients" section at the **bottom** of the Remote tab sidebar, only visible when count > 0.

Each client row shows:
- Green status dot
- `user@hostname` label

## Changes Required

1. **`ConnectedClient` model** — new file or added to existing models
2. **`HTTPServer`** — add `connectedClients` dict, register endpoint, clients list endpoint, prune timer
3. **`RemoteHostManager`** — add `registerClient()` piggybacked on `pollAgents()` cycle
4. **`MainWindowView`** — add Connected Clients section at bottom of Remote tab

## Future (v2)

- Kick functionality via `DELETE /api/clients/{clientId}` — kill SSH tunnel + optionally deny-list
- Show what agents the client is viewing
