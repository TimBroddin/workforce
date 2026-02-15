# First-Launch Setup Wizard

**Date**: 2026-02-15

## Overview

A single-page `.sheet` presented over `MainWindowView` on first launch. It explains what Workforce does, checks prerequisites, installs the CLI binary + hooks, and teaches the user how to use `workforce run`. Re-runnable from a Help menu item.

## Approach

Sheet overlay on MainWindowView. Chosen over full view replacement because it's the most macOS-native pattern and lets users see the app skeleton behind it.

## Layout (top to bottom)

### 1. Hero section
- App icon + "Welcome to Workforce"
- 2-3 sentence description: "Workforce monitors your Claude Code sessions in real-time. It tracks agents, subagents, tool usage, and notifications — all in one window. To work, it needs a small CLI tool and hooks installed in Claude Code."

### 2. Prerequisites checklist (read-only status items)
- **tmux** — green checkmark if found in `$PATH`, yellow warning + "Install via `brew install tmux`" if not
- **Claude CLI** — check for `claude` in `$PATH`, same pattern

### 3. Setup actions (interactive buttons)
- **Install workforce CLI** — Button that runs `HookInstaller.findBinary()` → `installBinary()`. Shows checkmark when done. If binary not found (no dev build available), shows an error.
- **Install Claude Code hooks** — Button that runs `HookInstaller.install()`. Shows checkmark when done. Disabled until CLI is installed.

### 4. Usage guide
- A small code block showing: `workforce run claude "Build the login page"` with a brief explanation that this launches a Claude agent tracked by Workforce.

### 5. "Get Started" button
- Dismisses the sheet
- Sets `@AppStorage("hasCompletedSetup")` to `true`
- Enabled even if setup steps aren't complete (user can skip)

## State management
- `@AppStorage("hasCompletedSetup")` flag in `MainWindowView` — controls `.sheet(isPresented:)`
- Re-running from Help menu just sets this flag back to `false` and re-presents the sheet

## Files to create/modify
- **New**: `SetupWizardView.swift` — the wizard view
- **Modify**: `WorkforceApp.swift` — add Help menu "Run Setup Wizard..." command
- **Modify**: `MainWindowView.swift` — add `.sheet` presentation gated on `@AppStorage`
