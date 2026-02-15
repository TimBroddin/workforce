# Preferences & Context Menus Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a Settings window for default terminal/IDE selection, context menus on agents (open in terminal, copy tmux command) and projects (open in IDE, open in Finder).

**Architecture:** New `AppLauncher` helper handles all external app launching (terminals via AppleScript/Process, IDEs via `open -a`). `SettingsView` provides Cmd+, preferences stored in `@AppStorage`. Context menus added via SwiftUI `.contextMenu` modifier on existing views.

**Tech Stack:** SwiftUI, AppKit (NSWorkspace, NSAppleScript, Process), @AppStorage/UserDefaults

---

### Task 1: Create AppLauncher helper

**Files:**
- Create: `Workforce for Claude Code/Workforce for Claude Code/Services/AppLauncher.swift`

**Step 1: Create AppLauncher.swift**

```swift
import AppKit

enum SupportedTerminal: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case iterm = "iTerm"
    case ghostty = "Ghostty"
    case warp = "Warp"
    case kitty = "Kitty"
    case alacritty = "Alacritty"
    case wezterm = "WezTerm"

    var id: String { rawValue }

    var bundleId: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .warp: "dev.warp.Warp-Stable"
        case .kitty: "net.kovidgoyal.kitty"
        case .alacritty: "org.alacritty"
        case .wezterm: "com.github.wez.wezterm"
        }
    }
}

enum SupportedIDE: String, CaseIterable, Identifiable {
    case vscode = "VS Code"
    case cursor = "Cursor"
    case windsurf = "Windsurf"
    case zed = "Zed"
    case xcode = "Xcode"
    case intellij = "IntelliJ IDEA"
    case sublime = "Sublime Text"
    case nova = "Nova"

    var id: String { rawValue }

    var appName: String {
        switch self {
        case .vscode: "Visual Studio Code"
        case .cursor: "Cursor"
        case .windsurf: "Windsurf"
        case .zed: "Zed"
        case .xcode: "Xcode"
        case .intellij: "IntelliJ IDEA"
        case .sublime: "Sublime Text"
        case .nova: "Nova"
        }
    }
}

enum AppLauncher {
    static func openInTerminal(tmuxSession: String, terminal: SupportedTerminal) {
        let tmuxPath = findTmux() ?? "/opt/homebrew/bin/tmux"
        let command = "\(tmuxPath) attach -t \(tmuxSession)"

        switch terminal {
        case .terminal:
            let script = """
            tell application "Terminal"
                activate
                do script "\(command)"
            end tell
            """
            runAppleScript(script)

        case .iterm:
            let script = """
            tell application "iTerm"
                activate
                create window with default profile command "\(command)"
            end tell
            """
            runAppleScript(script)

        default:
            // For Ghostty, Warp, Kitty, Alacritty, WezTerm — open the app then
            // use a shell wrapper since these don't have reliable AppleScript support
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", terminal.rawValue, "--args", "-e", command]
            try? process.run()
        }
    }

    static func openInIDE(path: String, ide: SupportedIDE) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", ide.appName, path]
        try? process.run()
    }

    static func openInFinder(path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    static func tmuxAttachCommand(session: String) -> String {
        let tmuxPath = findTmux() ?? "tmux"
        return "\(tmuxPath) attach -t \(session)"
    }

    private static func findTmux() -> String? {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runAppleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = NSAppleScript(source: source)
            script?.executeAndReturnError(nil)
        }
    }
}
```

**Step 2: Add file to Xcode project**

Add `AppLauncher.swift` to the Xcode project target. The file should be in the `Services/` group.

**Step 3: Build to verify it compiles**

Run: `xcodebuild -project "Workforce for Claude Code/Workforce for Claude Code.xcodeproj" -scheme "Workforce for Claude Code" build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add "Workforce for Claude Code/Workforce for Claude Code/Services/AppLauncher.swift"
git commit -m "feat: add AppLauncher helper for terminal and IDE launching"
```

---

### Task 2: Create SettingsView

**Files:**
- Create: `Workforce for Claude Code/Workforce for Claude Code/Views/SettingsView.swift`
- Modify: `Workforce for Claude Code/Workforce for Claude Code/Workforce_for_Claude_CodeApp.swift`

**Step 1: Create SettingsView.swift**

```swift
import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultTerminal") private var defaultTerminal: String = SupportedTerminal.terminal.rawValue
    @AppStorage("defaultIDE") private var defaultIDE: String = SupportedIDE.vscode.rawValue

    var body: some View {
        Form {
            Picker("Default Terminal", selection: $defaultTerminal) {
                ForEach(SupportedTerminal.allCases) { terminal in
                    Text(terminal.rawValue).tag(terminal.rawValue)
                }
            }

            Picker("Default IDE", selection: $defaultIDE) {
                ForEach(SupportedIDE.allCases) { ide in
                    Text(ide.rawValue).tag(ide.rawValue)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 350)
    }
}
```

**Step 2: Add Settings scene to the app**

In `Workforce_for_Claude_CodeApp.swift`, add a `Settings` scene after the `Window` scene:

```swift
var body: some Scene {
    Window("Workforce", id: "main") {
        MainWindowView(store: agentStore)
    }

    Settings {
        SettingsView()
    }
}
```

**Step 3: Build to verify**

Run: `xcodebuild -project "Workforce for Claude Code/Workforce for Claude Code.xcodeproj" -scheme "Workforce for Claude Code" build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add "Workforce for Claude Code/Workforce for Claude Code/Views/SettingsView.swift"
git add "Workforce for Claude Code/Workforce for Claude Code/Workforce_for_Claude_CodeApp.swift"
git commit -m "feat: add Settings window with terminal and IDE preferences"
```

---

### Task 3: Add context menus to MainWindowView

**Files:**
- Modify: `Workforce for Claude Code/Workforce for Claude Code/Views/MainWindowView.swift`

**Step 1: Add @AppStorage properties to MainWindowView**

Add these at the top of the struct alongside the existing `@State` properties:

```swift
@AppStorage("defaultTerminal") private var defaultTerminal: String = SupportedTerminal.terminal.rawValue
@AppStorage("defaultIDE") private var defaultIDE: String = SupportedIDE.vscode.rawValue
```

**Step 2: Add context menu to agent rows**

In the `sidebar` computed property, wrap the `AgentRowView` section (around line 84-95) to add a `.contextMenu` after `.onTapGesture`:

```swift
ForEach(agents(for: cwd)) { agent in
    AgentRowView(agent: agent)
        .background(
            selectedAgentId == agent.sessionId
                ? Color.accentColor.opacity(0.1)
                : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedAgentId = agent.sessionId
        }
        .contextMenu {
            if let tmux = agent.tmuxSession {
                Button("Open in Terminal") {
                    let terminal = SupportedTerminal(rawValue: defaultTerminal) ?? .terminal
                    AppLauncher.openInTerminal(tmuxSession: tmux, terminal: terminal)
                }
                Button("Copy tmux Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        AppLauncher.tmuxAttachCommand(session: tmux),
                        forType: .string
                    )
                }
            }
        }
}
```

**Step 3: Add context menu to section headers**

In `sectionHeader(for:)`, add a `.contextMenu` modifier after the existing `.onTapGesture`:

```swift
.onTapGesture {
    withAnimation(.easeInOut(duration: 0.15)) {
        if collapsedCwds.contains(cwd) {
            collapsedCwds.remove(cwd)
        } else {
            collapsedCwds.insert(cwd)
        }
    }
}
.contextMenu {
    let ide = SupportedIDE(rawValue: defaultIDE) ?? .vscode
    Button("Open in \(ide.rawValue)") {
        AppLauncher.openInIDE(path: cwd, ide: ide)
    }
    Button("Open in Finder") {
        AppLauncher.openInFinder(path: cwd)
    }
}
```

**Step 4: Build to verify**

Run: `xcodebuild -project "Workforce for Claude Code/Workforce for Claude Code.xcodeproj" -scheme "Workforce for Claude Code" build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add "Workforce for Claude Code/Workforce for Claude Code/Views/MainWindowView.swift"
git commit -m "feat: add context menus for agents and project folders"
```

---

### Task 4: Add new files to Xcode project

**Note:** If the Xcode project file (`project.pbxproj`) doesn't auto-discover files, the new `.swift` files need to be added to the project's file references and build phase. This may need to be done via Xcode GUI or by editing `project.pbxproj` directly.

**Step 1: Verify all files are included in the build**

Open the project in Xcode, check that `AppLauncher.swift` and `SettingsView.swift` appear under the correct groups and are included in the "Compile Sources" build phase.

**Step 2: Final build and test**

Run: `xcodebuild -project "Workforce for Claude Code/Workforce for Claude Code.xcodeproj" -scheme "Workforce for Claude Code" build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

Test manually:
1. Cmd+, opens Settings with two dropdowns
2. Right-click agent row shows "Open in Terminal" and "Copy tmux Command"
3. Right-click project header shows "Open in {IDE}" and "Open in Finder"
4. "Open in Finder" opens the correct folder
5. "Copy tmux Command" puts correct command on clipboard
