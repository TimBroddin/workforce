# Event Viewer Window Design

## Goal

Add a separate "Event Viewer" window to the Workforce app that shows all incoming socket messages in real time. Serves two purposes: debugging message flow (e.g. diagnosing why sessions don't register) and monitoring agent activity over time.

## Architecture

### New Files

**`Services/EventLog.swift`**
- `@Observable` class holding an array of `EventLogEntry`
- `EventLogEntry`: id (UUID), timestamp (Date), message (SocketMessage), rawJSON (String)
- `append(message:rawJSON:)` method — adds entry, trims to max 1000 entries
- `clear()` method
- Filtering computed properties by message type and session ID

**`Views/EventViewerWindow.swift`**
- SwiftUI view for the event viewer window content
- Toolbar: filter picker (by SocketMessageType), clear button
- List of event rows, each showing:
  - Timestamp (HH:mm:ss.SSS)
  - Message type as colored badge
  - Session ID (first 8 chars)
  - Summary text (e.g. tool name, status change)
- Clicking a row expands to show raw JSON in monospace font
- Auto-scrolls to bottom on new events

### Modified Files

**`Services/SocketServer.swift`**
- Accept an `EventLog` instance in addition to `AgentStore`
- In `processMessage()`, after decoding (or on failure), append to EventLog with the raw JSON string
- Also log decode failures so they're visible in the event viewer

**`Workforce_for_Claude_CodeApp.swift`**
- Create `EventLog` instance alongside `AgentStore`
- Pass `EventLog` to `SocketServer`
- Add second `Window("Event Viewer", id: "event-viewer")` scene
- Add `CommandGroup` with menu item: Window > Event Viewer (Cmd+Shift+E)

## Data Flow

```
CLI hook fires
  → workforce <event> (CLI reads stdin, sends to socket)
    → SocketServer.processMessage()
      → eventLog.append(message, rawJSON)  // NEW
      → agentStore.handleMessage(message)  // existing
```

## Event Viewer UI

```
┌─────────────────────────────────────────────────┐
│ Event Viewer                              [—][x]│
├─────────────────────────────────────────────────┤
│ Filter: [All Types ▾]              [Clear]      │
├─────────────────────────────────────────────────┤
│ 14:23:01.123  [register]    a1b2c3d4  session   │
│ 14:23:02.456  [updateTool]  a1b2c3d4  Bash      │
│ 14:23:03.789  [updateTool]  a1b2c3d4  —         │
│ ▼ 14:23:05.012  [notification] a1b2c3d4  input  │
│   {                                             │
│     "type": "notification",                     │
│     "sessionId": "a1b2c3d4...",                 │
│     "status": "waitingForInput",                │
│     ...                                         │
│   }                                             │
│ 14:23:10.345  [deregister]  a1b2c3d4  —         │
├─────────────────────────────────────────────────┤
│ 5 events                                        │
└─────────────────────────────────────────────────┘
```

## Badge Colors

| Message Type   | Color  |
|---------------|--------|
| register      | green  |
| deregister    | red    |
| updateTool    | blue   |
| updateStatus  | gray   |
| notification  | orange |
| subagentStart | purple |
| subagentStop  | purple |

## Constraints

- Max 1000 entries in memory (FIFO eviction)
- EventLog is `@Observable` so the view updates reactively
- Raw JSON preserved as String (not re-encoded) for exact fidelity
- Decode errors also logged with the raw JSON and error message
