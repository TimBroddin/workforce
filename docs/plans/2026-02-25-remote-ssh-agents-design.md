# Remote SSH Agent Support

**Date:** 2026-02-25
**Status:** Approved

## Overview

Add the ability to connect to remote machines over SSH and view/interact with/spawn agents running there, all from within the Workforce macOS app.

## Approach

SSH tunnel + HTTP API polling. The app establishes an SSH tunnel to forward the remote Workforce HTTP API to a local port, then polls it using the same JSON contract as local agents. Terminal interaction spawns `ssh -t` instead of local `tmux attach`.

## Data Model

### Agent changes

Add `host: String?` to `Agent`. `nil` means local, `"user@hostname"` means remote. Agents are keyed by `(host, sessionId)` to avoid identity collisions.

### RemoteHost model

```swift
struct RemoteHost: Codable, Identifiable {
    let id: UUID
    var label: String          // "Home Mac", "Work Server"
    var sshDestination: String // "tim@home.local"
    var sshPort: Int           // default 22
    var sshKeyPath: String?    // nil = use SSH agent/default key
    var isEnabled: Bool
}
```

Persisted in app support directory alongside `agents.json`.

## SSH Tunnel Lifecycle

Managed by `RemoteHostManager`:

1. **Discover remote port** — `ssh user@host "cat /tmp/workforce-*.port"`
2. **Open tunnel** — `ssh -N -L <localPort>:localhost:<remotePort> user@host`
3. **Poll** — `GET http://localhost:<localPort>/api/agents` every 5 seconds
4. **Health monitoring** — if SSH process dies, retry with exponential backoff (5s → 10s → 30s → 60s cap)
5. **Teardown** — SIGTERM on app quit or host disable

```swift
@Observable
final class RemoteHostManager {
    var hosts: [RemoteHost]
    var connections: [UUID: RemoteConnection]

    struct RemoteConnection {
        var status: ConnectionStatus  // .connecting, .connected, .error(String), .disabled
        var sshProcess: Process?
        var localPort: UInt16
        var agents: [Agent]
    }
}
```

`AgentStore` stays local-only. Remote agents live in `RemoteHostManager`. UI merges both.

## Terminal Interaction

Local agents: `forkpty` → `tmux -u attach -t <session>`
Remote agents: `forkpty` → `ssh -t user@host tmux -u attach -t <session>`

No new terminal view code. Small branch in `TerminalRepresentable.Coordinator.startPTY` to pick the command based on `agent.host`.

## Spawning Remote Agents

```
ssh user@host "tmux new-session -d -s workforce-<timestamp> -c <cwd> -- zsh -lc claude"
```

Then POST register event through the tunnel. Surface SSH errors in a sheet if the command fails.

## UI Changes

### Settings — "Remote Hosts" tab

Third tab alongside General and Beads. List of hosts with add/edit/remove. Each row: label, SSH destination, connection status indicator.

### Sidebar restructuring

Agents grouped by host, then by folder:

```
▼ Local
  ▼ ~/Projects/workforce
    Happy Heron (active)

▼ Home Mac (connected)
  ▼ ~/Projects/bigproject
    Bold Badger (active)
```

Host sections are collapsible. Local always first. Connection status shown next to remote host labels. Error state shows retry button.

### Footer

Agent count includes remote agents. Cost totals include remote agents.

### Context menus

Remote agents: same as local minus "Open in Finder". "Open in Terminal" becomes "SSH to agent".

## Auth

Key-based SSH auth only. No password auth support (would require an SSH library). Relies on the system `ssh` binary and SSH agent.

## Error Handling

- **Tunnel dies:** Agents stay visible with "disconnected" badge. Terminal shows reconnection message. Tunnel retries with backoff.
- **Remote app not running:** Status shows "Workforce not running on remote" with attempted SSH command.
- **SSH key issues:** Status shows SSH stderr for diagnosis.
- **Agent ID collisions:** `host` field disambiguates. Store keys on `(host, sessionId)`.

## App Lifecycle

- Tunnels torn down on app quit (SIGTERM in `applicationWillTerminate`).
- Tunnels reconnect on app launch if hosts are enabled.
- No tunnels while backgrounded. Reconnect when foregrounded.
- Spawning failures (claude not installed remotely) shown in a sheet.
