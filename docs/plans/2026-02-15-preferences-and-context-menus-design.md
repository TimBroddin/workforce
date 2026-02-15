# Preferences Pane & Context Menus

## Overview

Add a native macOS Settings window (Cmd+,) with terminal and IDE preferences, plus context menus on agent rows and project section headers.

## 1. Preferences Pane

**New file**: `SettingsView.swift`

Native SwiftUI `Settings` scene added to the app. Two `Picker` dropdowns:

**Default Terminal** (stored as `@AppStorage("defaultTerminal")`):
- Terminal, iTerm, Ghostty, Warp, Kitty, Alacritty, WezTerm

**Default IDE** (stored as `@AppStorage("defaultIDE")`):
- VS Code, Cursor, Windsurf, Zed, Xcode, IntelliJ IDEA, Sublime Text, Nova

Each option maps to a bundle identifier string for launching.

## 2. Agent Context Menu

Right-click on an `AgentRowView` row shows:

| Item | Action |
|------|--------|
| Open in Terminal | Open default terminal, run `tmux attach -t {tmuxSession}` |
| Copy tmux command | Copy `tmux attach -t {tmuxSession}` to pasteboard |

Only shown when `agent.tmuxSession != nil`.

## 3. Project Context Menu

Right-click on a cwd section header shows:

| Item | Action |
|------|--------|
| Open in {IDE name} | `open -a "AppName" "{cwd}"` |
| Open in Finder | `NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)` |

## 4. App Launching

**New file**: `AppLauncher.swift` — helper with two static methods:

- `openInTerminal(tmuxSession:)` — Uses AppleScript for Terminal.app/iTerm2, `open -a` for others, passing `tmux attach -t {session}` as the command.
- `openInIDE(path:)` — `open -a "AppName" "{path}"` (universal for all listed IDEs).

## 5. Files Changed

| File | Change |
|------|--------|
| `Workforce_for_Claude_CodeApp.swift` | Add `Settings` scene |
| `SettingsView.swift` | **New** — preferences UI |
| `AppLauncher.swift` | **New** — terminal/IDE launch helpers |
| `MainWindowView.swift` | Add `.contextMenu` to agent rows and section headers |
