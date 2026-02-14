# Workforce Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a macOS menu bar app + CLI that tracks all running Claude Code instances via hooks, shows their status with dicebear avatars, and delivers actionable notifications that focus the correct host window.

**Architecture:** Swift Package (WorkforceKit) shared between a menu bar app (WorkforceApp) and a CLI (WorkforceCLI). Communication via Unix domain socket. Claude Code hooks call the CLI on every lifecycle event; the app displays agent status and sends native notifications.

**Tech Stack:** Swift 6.2, SwiftUI, SwiftNIO (Unix socket), swift-argument-parser (CLI), UNUserNotificationCenter, NSAppleScript (window activation)

---

### Task 1: Create Swift Package structure (WorkforceKit + WorkforceCLI)

**Files:**
- Create: `WorkforceKit/Package.swift`
- Create: `WorkforceKit/Sources/WorkforceKit/Models/Agent.swift`
- Create: `WorkforceKit/Sources/WorkforceKit/Models/HookEvent.swift`
- Create: `WorkforceKit/Sources/WorkforceKit/Models/SocketMessage.swift`

**Step 1: Create Package.swift with both library and CLI targets**

```swift
// WorkforceKit/Package.swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WorkforceKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WorkforceKit", targets: ["WorkforceKit"]),
        .executable(name: "workforce", targets: ["WorkforceCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.76.0"),
    ],
    targets: [
        .target(
            name: "WorkforceKit",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "WorkforceCLI",
            dependencies: [
                "WorkforceKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "WorkforceKitTests",
            dependencies: ["WorkforceKit"]
        ),
    ]
)
```

**Step 2: Create Agent model**

```swift
// WorkforceKit/Sources/WorkforceKit/Models/Agent.swift

import Foundation

public enum AgentStatus: String, Codable, Sendable {
    case active
    case waitingForInput
    case waitingForPermission
    case idle
    case stopped
}

public enum HostApp: String, Codable, Sendable {
    case terminal
    case iterm
    case vscode
    case cursor
    case warp
    case unknown
}

public struct Agent: Codable, Identifiable, Sendable {
    public let sessionId: String
    public var id: String { sessionId }

    public let name: String
    public let avatarSeed: String

    public let cwd: String
    public let hostApp: HostApp
    public let hostBundleId: String?
    public let hostPid: Int32?

    public let startedAt: Date
    public var lastActivityAt: Date
    public var status: AgentStatus
    public var currentToolName: String?
    public var lastNotificationType: String?
    public var subagentCount: Int

    public init(
        sessionId: String,
        name: String,
        avatarSeed: String,
        cwd: String,
        hostApp: HostApp,
        hostBundleId: String?,
        hostPid: Int32?,
        startedAt: Date = Date(),
        lastActivityAt: Date = Date(),
        status: AgentStatus = .active,
        currentToolName: String? = nil,
        lastNotificationType: String? = nil,
        subagentCount: Int = 0
    ) {
        self.sessionId = sessionId
        self.name = name
        self.avatarSeed = avatarSeed
        self.cwd = cwd
        self.hostApp = hostApp
        self.hostBundleId = hostBundleId
        self.hostPid = hostPid
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.status = status
        self.currentToolName = currentToolName
        self.lastNotificationType = lastNotificationType
        self.subagentCount = subagentCount
    }
}
```

**Step 3: Create HookEvent model (decodable types for stdin JSON)**

```swift
// WorkforceKit/Sources/WorkforceKit/Models/HookEvent.swift

import Foundation

/// Common fields present in every hook event's stdin JSON
public struct HookEventBase: Decodable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let hookEventName: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
    }
}

/// PreToolUse / PostToolUse / PostToolUseFailure event
public struct ToolUseEvent: Decodable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let hookEventName: String
    public let toolName: String
    public let toolInput: ToolInput?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case toolInput = "tool_input"
    }

    public struct ToolInput: Decodable, Sendable {
        public let command: String?
        public let filePath: String?

        enum CodingKeys: String, CodingKey {
            case command
            case filePath = "file_path"
        }
    }
}

/// Notification event
public struct NotificationEvent: Decodable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let hookEventName: String
    public let type: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case type
    }
}

/// SessionStart event
public struct SessionStartEvent: Decodable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let hookEventName: String
    public let source: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case source
    }
}

/// SubagentStart / SubagentStop event
public struct SubagentEvent: Decodable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let hookEventName: String
    public let agentType: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case hookEventName = "hook_event_name"
        case agentType = "agent_type"
    }
}
```

**Step 4: Create SocketMessage model (protocol between CLI and app)**

```swift
// WorkforceKit/Sources/WorkforceKit/Models/SocketMessage.swift

import Foundation

public enum SocketMessageType: String, Codable, Sendable {
    case register
    case updateStatus
    case updateTool
    case notification
    case subagentStart
    case subagentStop
    case deregister
}

public struct SocketMessage: Codable, Sendable {
    public let type: SocketMessageType
    public let sessionId: String
    public let cwd: String
    public let timestamp: Date

    // Registration fields (only for .register)
    public var name: String?
    public var avatarSeed: String?
    public var hostApp: HostApp?
    public var hostBundleId: String?
    public var hostPid: Int32?

    // Status update fields
    public var status: AgentStatus?
    public var toolName: String?
    public var notificationType: String?
    public var agentType: String?

    public init(
        type: SocketMessageType,
        sessionId: String,
        cwd: String,
        timestamp: Date = Date(),
        name: String? = nil,
        avatarSeed: String? = nil,
        hostApp: HostApp? = nil,
        hostBundleId: String? = nil,
        hostPid: Int32? = nil,
        status: AgentStatus? = nil,
        toolName: String? = nil,
        notificationType: String? = nil,
        agentType: String? = nil
    ) {
        self.type = type
        self.sessionId = sessionId
        self.cwd = cwd
        self.timestamp = timestamp
        self.name = name
        self.avatarSeed = avatarSeed
        self.hostApp = hostApp
        self.hostBundleId = hostBundleId
        self.hostPid = hostPid
        self.status = status
        self.toolName = toolName
        self.notificationType = notificationType
        self.agentType = agentType
    }
}
```

**Step 5: Resolve dependencies and build**

Run: `cd WorkforceKit && swift build`
Expected: Builds successfully with no errors.

**Step 6: Commit**

```bash
git add WorkforceKit/
git commit -m "feat: add WorkforceKit package with Agent, HookEvent, and SocketMessage models"
```

---

### Task 2: Name generator and host detection utilities

**Files:**
- Create: `WorkforceKit/Sources/WorkforceKit/NameGenerator.swift`
- Create: `WorkforceKit/Sources/WorkforceKit/HostDetection.swift`
- Create: `WorkforceKit/Tests/WorkforceKitTests/NameGeneratorTests.swift`
- Create: `WorkforceKit/Tests/WorkforceKitTests/HostDetectionTests.swift`

**Step 1: Write tests for NameGenerator**

```swift
// WorkforceKit/Tests/WorkforceKitTests/NameGeneratorTests.swift

import Testing
@testable import WorkforceKit

@Test func generatesNameFromSeed() {
    let name = NameGenerator.generate(from: "abc123")
    #expect(!name.isEmpty)
    #expect(name.contains(" ")) // "Adjective Animal" format
}

@Test func sameInputProducesSameName() {
    let name1 = NameGenerator.generate(from: "session-xyz")
    let name2 = NameGenerator.generate(from: "session-xyz")
    #expect(name1 == name2)
}

@Test func differentInputsProduceDifferentNames() {
    let name1 = NameGenerator.generate(from: "session-1")
    let name2 = NameGenerator.generate(from: "session-2")
    #expect(name1 != name2)
}
```

**Step 2: Run tests to verify they fail**

Run: `cd WorkforceKit && swift test --filter NameGenerator`
Expected: FAIL — NameGenerator not found

**Step 3: Implement NameGenerator**

```swift
// WorkforceKit/Sources/WorkforceKit/NameGenerator.swift

import Foundation

public enum NameGenerator: Sendable {
    private static let adjectives = [
        "Swift", "Bold", "Calm", "Brave", "Keen",
        "Wise", "Quick", "Sharp", "Bright", "Steady",
        "Noble", "Clever", "Gentle", "Fierce", "Silent",
        "Lucky", "Nimble", "Proud", "Witty", "Lively",
        "Eager", "Daring", "Mellow", "Cosmic", "Radiant",
        "Humble", "Mighty", "Serene", "Zesty", "Vivid",
        "Rustic", "Astute",
    ]

    private static let animals = [
        "Falcon", "Otter", "Raven", "Penguin", "Fox",
        "Wolf", "Bear", "Hawk", "Lynx", "Puma",
        "Owl", "Crane", "Heron", "Badger", "Cobra",
        "Eagle", "Bison", "Tiger", "Viper", "Shark",
        "Gecko", "Finch", "Moose", "Squid", "Coral",
        "Beetle", "Osprey", "Marten", "Jackal", "Toucan",
        "Ibis", "Wombat",
    ]

    /// Generate a deterministic "Adjective Animal" name from a seed string.
    public static func generate(from seed: String) -> String {
        var hash: UInt64 = 5381
        for byte in seed.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }

        let adjIndex = Int(hash % UInt64(adjectives.count))
        let animalIndex = Int((hash / UInt64(adjectives.count)) % UInt64(animals.count))

        return "\(adjectives[adjIndex]) \(animals[animalIndex])"
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `cd WorkforceKit && swift test --filter NameGenerator`
Expected: All 3 tests PASS

**Step 5: Implement HostDetection**

```swift
// WorkforceKit/Sources/WorkforceKit/HostDetection.swift

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct HostInfo: Sendable {
    public let app: HostApp
    public let bundleId: String?
    public let pid: Int32?
}

public enum HostDetection: Sendable {
    /// Walk the process tree from the current process upward to find the host app.
    public static func detect() -> HostInfo {
        #if canImport(Darwin)
        var pid = getppid()
        // Walk up to 10 levels (workforce -> zsh -> ... -> Terminal.app)
        for _ in 0..<10 {
            guard pid > 1 else { break }
            if let name = processName(for: pid) {
                let lowered = name.lowercased()
                if lowered.contains("terminal") {
                    return HostInfo(app: .terminal, bundleId: "com.apple.Terminal", pid: pid)
                } else if lowered.contains("iterm") {
                    return HostInfo(app: .iterm, bundleId: "com.googlecode.iterm2", pid: pid)
                } else if lowered.contains("code helper") || lowered.contains("electron") {
                    // VS Code runs as Electron — check parent for the actual app
                    if let parentName = processName(for: parentPid(of: pid)) {
                        if parentName.lowercased().contains("cursor") {
                            return HostInfo(app: .cursor, bundleId: "com.todesktop.230313mzl4w4u92", pid: pid)
                        }
                    }
                    return HostInfo(app: .vscode, bundleId: "com.microsoft.VSCode", pid: pid)
                } else if lowered.contains("cursor") {
                    return HostInfo(app: .cursor, bundleId: "com.todesktop.230313mzl4w4u92", pid: pid)
                } else if lowered.contains("warp") {
                    return HostInfo(app: .warp, bundleId: "dev.warp.Warp-Stable", pid: pid)
                }
            }
            pid = parentPid(of: pid)
        }
        return HostInfo(app: .unknown, bundleId: nil, pid: nil)
        #else
        return HostInfo(app: .unknown, bundleId: nil, pid: nil)
        #endif
    }

    #if canImport(Darwin)
    private static func processName(for pid: Int32) -> String? {
        let nameBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
        defer { nameBuffer.deallocate() }
        let result = proc_pidpath(pid, nameBuffer, UInt32(MAXPATHLEN))
        guard result > 0 else { return nil }
        return String(cString: nameBuffer).components(separatedBy: "/").last
    }

    private static func parentPid(of pid: Int32) -> Int32 {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size > 0 else { return 1 }
        return Int32(info.pbi_ppid)
    }
    #endif
}
```

Note: `proc_pidpath` and `proc_pidinfo` are from `libproc.h`. We need to add `import Darwin` and potentially a bridging header or modulemap. If `proc_bsdinfo` isn't directly available, we'll use `sysctl` with `KERN_PROC` instead. The implementation may need adjustment at build time.

**Step 6: Run full test suite**

Run: `cd WorkforceKit && swift test`
Expected: All tests pass

**Step 7: Commit**

```bash
git add WorkforceKit/Sources/WorkforceKit/NameGenerator.swift WorkforceKit/Sources/WorkforceKit/HostDetection.swift WorkforceKit/Tests/
git commit -m "feat: add NameGenerator and HostDetection utilities"
```

---

### Task 3: Socket client (CLI side)

**Files:**
- Create: `WorkforceKit/Sources/WorkforceCLI/SocketClient.swift`

**Step 1: Implement SocketClient**

The CLI needs a fire-and-forget socket client. Connect to `/tmp/workforce-{uid}.sock`, send a JSON-encoded `SocketMessage`, disconnect. Must complete in <50ms and never block.

```swift
// WorkforceKit/Sources/WorkforceCLI/SocketClient.swift

import Foundation
import NIOCore
import NIOPosix
import WorkforceKit

enum SocketClient {
    static let socketPath = "/tmp/workforce-\(getuid()).sock"

    /// Send a message to the Workforce app. Returns silently if the app isn't running.
    static func send(_ message: SocketMessage) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        do {
            let data = try JSONEncoder().encode(message)
            // Append newline as message delimiter
            let payload = data + Data([0x0A])

            let bootstrap = ClientBootstrap(group: group)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .connectTimeout(.milliseconds(100))
                .channelInitializer { channel in
                    channel.eventLoop.makeSucceededVoidFuture()
                }

            let channel = try bootstrap
                .connect(unixDomainSocketPath: socketPath)
                .wait()

            var buffer = channel.allocator.buffer(capacity: payload.count)
            buffer.writeBytes(payload)
            try channel.writeAndFlush(buffer).wait()
            try channel.close().wait()
        } catch {
            // App not running or socket unavailable — exit silently
        }
    }
}
```

**Step 2: Build to verify**

Run: `cd WorkforceKit && swift build`
Expected: Builds successfully

**Step 3: Commit**

```bash
git add WorkforceKit/Sources/WorkforceCLI/SocketClient.swift
git commit -m "feat: add socket client for CLI-to-app communication"
```

---

### Task 4: CLI commands (all hook handlers + install/uninstall)

**Files:**
- Create: `WorkforceKit/Sources/WorkforceCLI/Workforce.swift` (main entry point)
- Create: `WorkforceKit/Sources/WorkforceCLI/Commands/SessionStartCommand.swift`
- Create: `WorkforceKit/Sources/WorkforceCLI/Commands/ToolUseCommand.swift`
- Create: `WorkforceKit/Sources/WorkforceCLI/Commands/NotificationCommand.swift`
- Create: `WorkforceKit/Sources/WorkforceCLI/Commands/StopCommand.swift`
- Create: `WorkforceKit/Sources/WorkforceCLI/Commands/SessionEndCommand.swift`
- Create: `WorkforceKit/Sources/WorkforceCLI/Commands/SubagentCommand.swift`
- Create: `WorkforceKit/Sources/WorkforceCLI/Commands/InstallHooksCommand.swift`
- Create: `WorkforceKit/Sources/WorkforceCLI/Commands/UninstallHooksCommand.swift`

**Step 1: Create main entry point**

```swift
// WorkforceKit/Sources/WorkforceCLI/Workforce.swift

import ArgumentParser

@main
struct Workforce: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workforce",
        abstract: "CLI companion for Workforce for Claude Code",
        subcommands: [
            SessionStartCommand.self,
            PreToolUseCommand.self,
            PostToolUseCommand.self,
            PostToolUseFailureCommand.self,
            NotificationCommand.self,
            StopCommand.self,
            SessionEndCommand.self,
            SubagentStartCommand.self,
            SubagentStopCommand.self,
            InstallHooksCommand.self,
            UninstallHooksCommand.self,
        ]
    )
}
```

**Step 2: Create SessionStartCommand**

```swift
// WorkforceKit/Sources/WorkforceCLI/Commands/SessionStartCommand.swift

import ArgumentParser
import Foundation
import WorkforceKit

struct SessionStartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session-start",
        abstract: "Handle SessionStart hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(SessionStartEvent.self, from: data)
        let host = HostDetection.detect()

        let message = SocketMessage(
            type: .register,
            sessionId: event.sessionId,
            cwd: event.cwd,
            name: NameGenerator.generate(from: event.sessionId),
            avatarSeed: event.sessionId,
            hostApp: host.app,
            hostBundleId: host.bundleId,
            hostPid: host.pid,
            status: .active
        )
        SocketClient.send(message)
    }
}

/// Read all of stdin into Data.
func readStdin() throws -> Data {
    var data = Data()
    while let byte = try? FileHandle.standardInput.read(upToCount: 4096) {
        if byte.isEmpty { break }
        data.append(byte)
    }
    return data
}
```

**Step 3: Create ToolUse commands (Pre, Post, PostFailure — share pattern)**

```swift
// WorkforceKit/Sources/WorkforceCLI/Commands/ToolUseCommand.swift

import ArgumentParser
import Foundation
import WorkforceKit

struct PreToolUseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pre-tool-use",
        abstract: "Handle PreToolUse hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(ToolUseEvent.self, from: data)

        let message = SocketMessage(
            type: .updateTool,
            sessionId: event.sessionId,
            cwd: event.cwd,
            status: .active,
            toolName: event.toolName
        )
        SocketClient.send(message)
    }
}

struct PostToolUseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "post-tool-use",
        abstract: "Handle PostToolUse hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(ToolUseEvent.self, from: data)

        let message = SocketMessage(
            type: .updateTool,
            sessionId: event.sessionId,
            cwd: event.cwd,
            status: .active,
            toolName: nil // tool finished
        )
        SocketClient.send(message)
    }
}

struct PostToolUseFailureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "post-tool-use-failure",
        abstract: "Handle PostToolUseFailure hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(ToolUseEvent.self, from: data)

        let message = SocketMessage(
            type: .updateTool,
            sessionId: event.sessionId,
            cwd: event.cwd,
            status: .active,
            toolName: nil
        )
        SocketClient.send(message)
    }
}
```

**Step 4: Create NotificationCommand**

```swift
// WorkforceKit/Sources/WorkforceCLI/Commands/NotificationCommand.swift

import ArgumentParser
import Foundation
import WorkforceKit

struct NotificationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notification",
        abstract: "Handle Notification hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(NotificationEvent.self, from: data)

        let status: AgentStatus
        switch event.type {
        case "permission_prompt":
            status = .waitingForPermission
        case "idle_prompt":
            status = .waitingForInput
        default:
            status = .waitingForInput
        }

        let message = SocketMessage(
            type: .notification,
            sessionId: event.sessionId,
            cwd: event.cwd,
            status: status,
            notificationType: event.type
        )
        SocketClient.send(message)
    }
}
```

**Step 5: Create StopCommand, SessionEndCommand, SubagentCommands**

```swift
// WorkforceKit/Sources/WorkforceCLI/Commands/StopCommand.swift

import ArgumentParser
import Foundation
import WorkforceKit

struct StopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Handle Stop hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(HookEventBase.self, from: data)

        let message = SocketMessage(
            type: .updateStatus,
            sessionId: event.sessionId,
            cwd: event.cwd,
            status: .idle
        )
        SocketClient.send(message)
    }
}
```

```swift
// WorkforceKit/Sources/WorkforceCLI/Commands/SessionEndCommand.swift

import ArgumentParser
import Foundation
import WorkforceKit

struct SessionEndCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session-end",
        abstract: "Handle SessionEnd hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(HookEventBase.self, from: data)

        let message = SocketMessage(
            type: .deregister,
            sessionId: event.sessionId,
            cwd: event.cwd
        )
        SocketClient.send(message)
    }
}
```

```swift
// WorkforceKit/Sources/WorkforceCLI/Commands/SubagentCommand.swift

import ArgumentParser
import Foundation
import WorkforceKit

struct SubagentStartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "subagent-start",
        abstract: "Handle SubagentStart hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(SubagentEvent.self, from: data)

        let message = SocketMessage(
            type: .subagentStart,
            sessionId: event.sessionId,
            cwd: event.cwd,
            status: .active,
            agentType: event.agentType
        )
        SocketClient.send(message)
    }
}

struct SubagentStopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "subagent-stop",
        abstract: "Handle SubagentStop hook event"
    )

    func run() throws {
        let data = try readStdin()
        let event = try JSONDecoder().decode(SubagentEvent.self, from: data)

        let message = SocketMessage(
            type: .subagentStop,
            sessionId: event.sessionId,
            cwd: event.cwd,
            agentType: event.agentType
        )
        SocketClient.send(message)
    }
}
```

**Step 6: Create InstallHooksCommand**

```swift
// WorkforceKit/Sources/WorkforceCLI/Commands/InstallHooksCommand.swift

import ArgumentParser
import Foundation
import WorkforceKit

struct InstallHooksCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-hooks",
        abstract: "Install Workforce hooks into ~/.claude/settings.json"
    )

    func run() throws {
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")

        // Read existing settings
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsPath.path) {
            let data = try Data(contentsOf: settingsPath)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings = json
            }
        }

        // Get or create hooks dict
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Find the workforce binary path
        let binaryPath = ProcessInfo.processInfo.arguments[0]

        let hookEvents: [(String, String)] = [
            ("SessionStart", "session-start"),
            ("PreToolUse", "pre-tool-use"),
            ("PostToolUse", "post-tool-use"),
            ("PostToolUseFailure", "post-tool-use-failure"),
            ("Notification", "notification"),
            ("SubagentStart", "subagent-start"),
            ("SubagentStop", "subagent-stop"),
            ("Stop", "stop"),
            ("SessionEnd", "session-end"),
        ]

        var installed = 0
        for (event, subcommand) in hookEvents {
            let command = "\(binaryPath) \(subcommand)"
            var eventHooks = hooks[event] as? [[String: Any]] ?? []

            // Check if workforce hook already exists
            let alreadyInstalled = eventHooks.contains { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { ($0["command"] as? String)?.contains("workforce") == true }
            }

            if !alreadyInstalled {
                let entry: [String: Any] = [
                    "matcher": "",
                    "hooks": [
                        ["type": "command", "command": command]
                    ]
                ]
                eventHooks.append(entry)
                hooks[event] = eventHooks
                installed += 1
            }
        }

        settings["hooks"] = hooks

        // Write back
        let output = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try output.write(to: settingsPath)

        print("Installed \(installed) hooks. (\(hookEvents.count - installed) already present)")
        print("Settings written to: \(settingsPath.path)")
    }
}
```

**Step 7: Create UninstallHooksCommand**

```swift
// WorkforceKit/Sources/WorkforceCLI/Commands/UninstallHooksCommand.swift

import ArgumentParser
import Foundation

struct UninstallHooksCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall-hooks",
        abstract: "Remove Workforce hooks from ~/.claude/settings.json"
    )

    func run() throws {
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")

        guard FileManager.default.fileExists(atPath: settingsPath.path) else {
            print("No settings file found at \(settingsPath.path)")
            return
        }

        let data = try Data(contentsOf: settingsPath)
        guard var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else {
            print("No hooks found in settings.")
            return
        }

        var removed = 0
        for (event, var entries) in hooks {
            guard var eventEntries = entries as? [[String: Any]] else { continue }
            let before = eventEntries.count
            eventEntries.removeAll { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { ($0["command"] as? String)?.contains("workforce") == true }
            }
            removed += before - eventEntries.count
            hooks[event] = eventEntries.isEmpty ? nil : eventEntries
        }

        settings["hooks"] = hooks
        let output = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try output.write(to: settingsPath)

        print("Removed \(removed) workforce hooks.")
    }
}
```

**Step 8: Build the CLI**

Run: `cd WorkforceKit && swift build`
Expected: Builds successfully

**Step 9: Test install-hooks manually**

Run: `cd WorkforceKit && swift run workforce install-hooks`
Expected: Prints "Installed 9 hooks." and `~/.claude/settings.json` has workforce entries alongside existing hooks.

**Step 10: Test uninstall-hooks**

Run: `cd WorkforceKit && swift run workforce uninstall-hooks`
Expected: Prints "Removed 9 workforce hooks." and existing hooks (ElevenLabs) still present.

**Step 11: Commit**

```bash
git add WorkforceKit/Sources/WorkforceCLI/
git commit -m "feat: add CLI commands for all hook events and install/uninstall"
```

---

### Task 5: Socket server (App side)

**Files:**
- Modify: `Workforce for Claude Code/Workforce for Claude Code/Workforce_for_Claude_CodeApp.swift`
- Create: `Workforce for Claude Code/Workforce for Claude Code/Services/SocketServer.swift`
- Create: `Workforce for Claude Code/Workforce for Claude Code/Services/AgentStore.swift`

The Xcode app needs to add WorkforceKit as a local package dependency first.

**Step 1: Add WorkforceKit dependency to the Xcode project**

Open the Xcode project and add the local package `../WorkforceKit` as a dependency. Alternatively, modify the `project.pbxproj` to reference the local package. (This step is best done in Xcode GUI: File > Add Package Dependencies > Add Local > select `WorkforceKit/`.)

**Step 2: Create AgentStore**

```swift
// Workforce for Claude Code/Workforce for Claude Code/Services/AgentStore.swift

import Foundation
import Observation
import WorkforceKit

@Observable
final class AgentStore {
    var agents: [String: Agent] = [:]

    /// Sorted agents — waiting states first, then by lastActivityAt descending.
    var sortedAgents: [Agent] {
        agents.values.sorted { a, b in
            let aPriority = statusPriority(a.status)
            let bPriority = statusPriority(b.status)
            if aPriority != bPriority { return aPriority < bPriority }
            return a.lastActivityAt > b.lastActivityAt
        }
    }

    func handleMessage(_ message: SocketMessage) {
        switch message.type {
        case .register:
            let agent = Agent(
                sessionId: message.sessionId,
                name: message.name ?? NameGenerator.generate(from: message.sessionId),
                avatarSeed: message.avatarSeed ?? message.sessionId,
                cwd: message.cwd,
                hostApp: message.hostApp ?? .unknown,
                hostBundleId: message.hostBundleId,
                hostPid: message.hostPid,
                status: message.status ?? .active
            )
            agents[message.sessionId] = agent

        case .updateStatus:
            guard var agent = agents[message.sessionId] else {
                // Agent not registered yet — auto-register with minimal info
                registerMinimal(from: message)
                return
            }
            agent.lastActivityAt = message.timestamp
            if let status = message.status { agent.status = status }
            agents[message.sessionId] = agent

        case .updateTool:
            guard var agent = agents[message.sessionId] else {
                registerMinimal(from: message)
                return
            }
            agent.lastActivityAt = message.timestamp
            agent.currentToolName = message.toolName
            if let status = message.status { agent.status = status }
            agents[message.sessionId] = agent

        case .notification:
            guard var agent = agents[message.sessionId] else {
                registerMinimal(from: message)
                return
            }
            agent.lastActivityAt = message.timestamp
            agent.lastNotificationType = message.notificationType
            if let status = message.status { agent.status = status }
            agents[message.sessionId] = agent

        case .subagentStart:
            guard var agent = agents[message.sessionId] else {
                registerMinimal(from: message)
                return
            }
            agent.lastActivityAt = message.timestamp
            agent.subagentCount += 1
            agents[message.sessionId] = agent

        case .subagentStop:
            guard var agent = agents[message.sessionId] else { return }
            agent.lastActivityAt = message.timestamp
            agent.subagentCount = max(0, agent.subagentCount - 1)
            agents[message.sessionId] = agent

        case .deregister:
            agents.removeValue(forKey: message.sessionId)
        }
    }

    /// Prune agents that haven't been seen in 5 minutes.
    func pruneStale() {
        let cutoff = Date().addingTimeInterval(-300)
        for (id, agent) in agents {
            if agent.lastActivityAt < cutoff && agent.status != .stopped {
                agents.removeValue(forKey: id)
            }
        }
    }

    private func registerMinimal(from message: SocketMessage) {
        let agent = Agent(
            sessionId: message.sessionId,
            name: NameGenerator.generate(from: message.sessionId),
            avatarSeed: message.sessionId,
            cwd: message.cwd,
            hostApp: message.hostApp ?? .unknown,
            hostBundleId: message.hostBundleId,
            hostPid: message.hostPid,
            status: message.status ?? .active,
            currentToolName: message.toolName
        )
        agents[message.sessionId] = agent
    }

    private func statusPriority(_ status: AgentStatus) -> Int {
        switch status {
        case .waitingForPermission: 0
        case .waitingForInput: 1
        case .active: 2
        case .idle: 3
        case .stopped: 4
        }
    }
}
```

**Step 3: Create SocketServer**

```swift
// Workforce for Claude Code/Workforce for Claude Code/Services/SocketServer.swift

import Foundation
import Network
import WorkforceKit

final class SocketServer {
    private var listener: NWListener?
    private let store: AgentStore
    private let socketPath: String

    init(store: AgentStore) {
        self.store = store
        self.socketPath = "/tmp/workforce-\(getuid()).sock"
    }

    func start() throws {
        // Remove stale socket file
        let fm = FileManager.default
        if fm.fileExists(atPath: socketPath) {
            try fm.removeItem(atPath: socketPath)
        }

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        listener = try NWListener(using: params)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveData(on: connection, accumulated: Data())
    }

    private func receiveData(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }

            var buffer = accumulated
            if let content { buffer.append(content) }

            if isComplete || error != nil {
                // Parse the complete message
                if !buffer.isEmpty {
                    self.processMessage(buffer)
                }
                connection.cancel()
            } else {
                // Keep reading
                self.receiveData(on: connection, accumulated: buffer)
            }
        }
    }

    private func processMessage(_ data: Data) {
        // Messages are newline-delimited JSON
        let lines = data.split(separator: UInt8(ascii: "\n"))
        for line in lines {
            do {
                let message = try JSONDecoder().decode(SocketMessage.self, from: Data(line))
                store.handleMessage(message)
            } catch {
                // Malformed message — ignore
            }
        }
    }
}
```

Note: This uses Foundation's `Network` framework (`NWListener`) instead of SwiftNIO for the app side, keeping the app dependency-free from SwiftNIO. The CLI uses SwiftNIO because it needs a synchronous fire-and-forget client. The app can use the higher-level `Network` framework.

**Step 4: Update App entry point to be a menu bar app**

```swift
// Workforce for Claude Code/Workforce for Claude Code/Workforce_for_Claude_CodeApp.swift

import SwiftUI

@main
struct WorkforceApp: App {
    @State private var agentStore = AgentStore()
    @State private var socketServer: SocketServer?

    var body: some Scene {
        MenuBarExtra("Workforce", systemImage: "person.3.fill") {
            ContentView(store: agentStore)
        }
        .menuBarExtraStyle(.window)
    }

    init() {
        let store = AgentStore()
        _agentStore = State(initialValue: store)
        let server = SocketServer(store: store)
        _socketServer = State(initialValue: server)
        try? server.start()
    }
}
```

**Step 5: Disable App Sandbox in Xcode**

In the Xcode project, set `ENABLE_APP_SANDBOX = NO` in both Debug and Release build settings. The app needs unrestricted access to `/tmp/` for the Unix socket and process inspection APIs.

Also set `LSUIElement = YES` in Info.plist (or via build settings `INFOPLIST_KEY_LSUIElement = YES`) to hide from dock.

**Step 6: Build in Xcode**

Run: Open in Xcode, build (Cmd+B)
Expected: Builds and shows menu bar icon

**Step 7: Commit**

```bash
git add "Workforce for Claude Code/"
git commit -m "feat: add socket server, agent store, and menu bar app shell"
```

---

### Task 6: SwiftUI views (agent list, status badges, avatars)

**Files:**
- Rewrite: `Workforce for Claude Code/Workforce for Claude Code/ContentView.swift`
- Create: `Workforce for Claude Code/Workforce for Claude Code/Views/AgentRowView.swift`
- Create: `Workforce for Claude Code/Workforce for Claude Code/Views/StatusBadge.swift`
- Create: `Workforce for Claude Code/Workforce for Claude Code/Views/AvatarView.swift`

**Step 1: Create StatusBadge**

```swift
// Views/StatusBadge.swift

import SwiftUI
import WorkforceKit

struct StatusBadge: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch status {
        case .active: .green
        case .waitingForInput: .orange
        case .waitingForPermission: .red
        case .idle: .gray
        case .stopped: .gray.opacity(0.5)
        }
    }

    private var label: String {
        switch status {
        case .active: "Active"
        case .waitingForInput: "Waiting for input"
        case .waitingForPermission: "Needs permission"
        case .idle: "Idle"
        case .stopped: "Stopped"
        }
    }
}
```

**Step 2: Create AvatarView**

```swift
// Views/AvatarView.swift

import SwiftUI

struct AvatarView: View {
    let seed: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .overlay {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: seed) {
            await loadAvatar()
        }
    }

    private func loadAvatar() async {
        // Check cache first
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Workforce/avatars")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cached = cacheDir.appendingPathComponent("\(seed).png")

        if let data = try? Data(contentsOf: cached), let img = NSImage(data: data) {
            self.image = img
            return
        }

        // Fetch from dicebear
        guard let url = URL(string: "https://api.dicebear.com/9.x/bottts-neutral/png?seed=\(seed)&size=64") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        try? data.write(to: cached)
        if let img = NSImage(data: data) {
            self.image = img
        }
    }
}
```

**Step 3: Create AgentRowView**

```swift
// Views/AgentRowView.swift

import SwiftUI
import WorkforceKit

struct AgentRowView: View {
    let agent: Agent
    var onFocus: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(seed: agent.avatarSeed)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(agent.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    StatusBadge(status: agent.status)
                }

                Text(abbreviatePath(agent.cwd))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(agent.hostApp.rawValue.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let tool = agent.currentToolName {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("using \(tool)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if agent.subagentCount > 0 {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("\(agent.subagentCount) subagent\(agent.subagentCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Button("Focus", action: onFocus)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
```

**Step 4: Rewrite ContentView**

```swift
// ContentView.swift

import SwiftUI
import WorkforceKit

struct ContentView: View {
    let store: AgentStore

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Workforce")
                    .font(.headline)
                Spacer()
                Button {
                    // TODO: install hooks
                } label: {
                    Label("Install", systemImage: "gear")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if store.sortedAgents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.3.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No active agents")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Start a Claude Code session to see it here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.sortedAgents) { agent in
                            AgentRowView(agent: agent) {
                                focusAgent(agent)
                            }
                            Divider()
                                .padding(.horizontal, 8)
                        }
                    }
                }
                .frame(maxHeight: 400)
            }

            Divider()

            // Footer
            HStack {
                Text("\(store.agents.count) agent\(store.agents.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 380)
    }

    private func focusAgent(_ agent: Agent) {
        // TODO: implement WindowActivator
    }
}
```

**Step 5: Delete unused Item.swift**

Remove `Item.swift` — no longer using SwiftData.

**Step 6: Build in Xcode**

Expected: Builds and shows empty state in menu bar popover

**Step 7: Commit**

```bash
git add "Workforce for Claude Code/"
git commit -m "feat: add agent list UI with status badges, avatars, and row views"
```

---

### Task 7: Notification manager

**Files:**
- Create: `Workforce for Claude Code/Workforce for Claude Code/Services/NotificationManager.swift`
- Modify: `Workforce for Claude Code/Workforce for Claude Code/Services/AgentStore.swift` (call notification manager on status change)

**Step 1: Create NotificationManager**

```swift
// Services/NotificationManager.swift

import Foundation
import UserNotifications
import AppKit
import WorkforceKit

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyIfNeeded(agent: Agent, previousStatus: AgentStatus?) {
        // Only notify on transition TO waiting states
        guard agent.status == .waitingForInput || agent.status == .waitingForPermission else { return }
        guard previousStatus != agent.status else { return }

        // Don't notify if the host app is frontmost
        if let bundleId = agent.hostBundleId,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = agent.name

        switch agent.status {
        case .waitingForInput:
            content.body = "Waiting for your input"
        case .waitingForPermission:
            content.body = "Needs permission to continue"
        default:
            return
        }

        content.sound = .default
        content.userInfo = ["sessionId": agent.sessionId]

        let request = UNNotificationRequest(
            identifier: "workforce-\(agent.sessionId)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    // Handle notification click
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let sessionId = response.notification.request.content.userInfo["sessionId"] as? String
        if let sessionId {
            // Post notification so the app can focus the agent
            NotificationCenter.default.post(
                name: .focusAgent,
                object: nil,
                userInfo: ["sessionId": sessionId]
            )
        }
    }

    // Show notification even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

extension Notification.Name {
    static let focusAgent = Notification.Name("focusAgent")
}
```

**Step 2: Update AgentStore to trigger notifications**

In `AgentStore.handleMessage`, before updating agent status, capture the previous status and call `NotificationManager.shared.notifyIfNeeded(agent:previousStatus:)` after the update.

**Step 3: Build and test**

Expected: Build succeeds. Launching the app requests notification permission.

**Step 4: Commit**

```bash
git add "Workforce for Claude Code/"
git commit -m "feat: add notification manager with host-app-aware delivery"
```

---

### Task 8: Window activation (Focus button)

**Files:**
- Create: `Workforce for Claude Code/Workforce for Claude Code/Services/WindowActivator.swift`
- Modify: `ContentView.swift` (wire up focusAgent)

**Step 1: Create WindowActivator**

```swift
// Services/WindowActivator.swift

import AppKit
import WorkforceKit

enum WindowActivator {
    static func activate(_ agent: Agent) {
        switch agent.hostApp {
        case .terminal:
            activateViaAppleScript(bundleId: "com.apple.Terminal")
        case .iterm:
            activateViaAppleScript(bundleId: "com.googlecode.iterm2")
        case .vscode:
            activateViaAppleScript(bundleId: "com.microsoft.VSCode")
        case .cursor:
            activateViaAppleScript(bundleId: "com.todesktop.230313mzl4w4u92")
        case .warp:
            activateViaAppleScript(bundleId: "dev.warp.Warp-Stable")
        case .unknown:
            break
        }
    }

    private static func activateViaAppleScript(bundleId: String) {
        let source = """
        tell application id "\(bundleId)"
            activate
        end tell
        """
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
        }
    }
}
```

**Step 2: Wire up in ContentView**

Replace `focusAgent` body:
```swift
private func focusAgent(_ agent: Agent) {
    WindowActivator.activate(agent)
}
```

**Step 3: Build and test manually**

Open a Terminal and verify clicking Focus brings Terminal to front.

**Step 4: Commit**

```bash
git add "Workforce for Claude Code/"
git commit -m "feat: add window activation via AppleScript for Focus button"
```

---

### Task 9: Menu bar icon with status indicator

**Files:**
- Modify: `Workforce_for_Claude_CodeApp.swift` (dynamic menu bar icon)

**Step 1: Update menu bar icon to reflect agent fleet status**

```swift
// In WorkforceApp, change MenuBarExtra to use a dynamic label:
MenuBarExtra {
    ContentView(store: agentStore)
} label: {
    let hasPermission = agentStore.agents.values.contains { $0.status == .waitingForPermission }
    let hasWaiting = agentStore.agents.values.contains { $0.status == .waitingForInput }

    if hasPermission {
        Image(systemName: "person.3.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.red, .primary)
    } else if hasWaiting {
        Image(systemName: "person.3.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.orange, .primary)
    } else {
        Image(systemName: "person.3.fill")
    }
}
```

**Step 2: Build and verify**

Expected: Menu bar icon changes color when agents are in waiting states.

**Step 3: Commit**

```bash
git add "Workforce for Claude Code/"
git commit -m "feat: dynamic menu bar icon reflecting agent fleet status"
```

---

### Task 10: Stale agent cleanup timer

**Files:**
- Modify: `Workforce_for_Claude_CodeApp.swift` (add Timer)

**Step 1: Add a 60-second timer that calls `agentStore.pruneStale()`**

In the app's `init` or via a `.task` modifier on ContentView, set up a repeating timer:

```swift
// Add to ContentView or WorkforceApp
.task {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        store.pruneStale()
    }
}
```

**Step 2: Build and verify**

Expected: Stale agents disappear after 5 minutes of inactivity.

**Step 3: Commit**

```bash
git add "Workforce for Claude Code/"
git commit -m "feat: add 60-second stale agent cleanup timer"
```

---

### Task 11: End-to-end integration test

**Step 1: Build and install the CLI**

```bash
cd WorkforceKit && swift build -c release
cp .build/release/workforce /usr/local/bin/workforce
```

**Step 2: Launch the app from Xcode**

**Step 3: Install hooks**

```bash
workforce install-hooks
```

**Step 4: Start a Claude Code session**

Verify the agent appears in the menu bar popover with a name and avatar.

**Step 5: Trigger various events**

- Use tools — verify "using Edit" / "using Bash" appears
- Let Claude stop — verify status changes to "Idle"
- Wait for notification — verify macOS notification appears
- Click Focus — verify correct window activates
- End session — verify agent disappears

**Step 6: Commit final state**

```bash
git add -A
git commit -m "chore: integration-tested workforce v1"
```

---

Plan complete and saved to `docs/plans/2026-02-14-workforce-implementation.md`. Two execution options:

**1. Subagent-Driven (this session)** — I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** — Open new session with executing-plans, batch execution with checkpoints

Which approach?