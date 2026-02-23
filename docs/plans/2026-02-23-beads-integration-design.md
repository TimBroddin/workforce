# Beads Integration Enhancement Design

**Date:** 2026-02-23

## Overview

Enhance beads integration with: tabbed settings pane (General / Beads), support for both `bd` (steveyegge/beads) and `br` (beads_rust) implementations, project-level beads init with optional CLAUDE.md/AGENTS.md setup, and GUI issue creation/closing.

## 1. Settings: Split into General / Beads tabs

**SettingsView.swift** gets a `TabView` wrapper with two tabs.

### General tab
All existing settings content unchanged.

### Beads tab
- **Implementation picker**: `@AppStorage("beadsImplementation")` with options `bd` and `br`. Defaults to whichever is installed; `br` preferred if both present.
- **Install status rows** (same pattern as CLI section in General):
  - `bd` — shows installed/not-installed, Install button runs `curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash`
  - `br` — shows installed/not-installed, Install button runs `curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh | bash`
  - `bv` — shows installed/not-installed, Install via Homebrew (`brew install dicklesworthstone/tap/bv`) or script (moved from BeadsViewerView install UI)

## 2. "Setup Beads" when no .beads folder

In **ProjectDetailView**, when `hasBeads == false`, the Issues tab slot shows a "Setup Beads" call-to-action instead of `BeadsViewerView`.

Flow:
1. User clicks "Setup Beads"
2. Runs `bd init` or `br init` (per `@AppStorage("beadsImplementation")`) in the project's `cwd`
3. On success, shows post-init prompt: "Add beads instructions to CLAUDE.md / AGENTS.md?"
4. If yes, appends a standard beads usage block to those files if they exist in the project directory
5. Refreshes `hasBeads`, switches to the Issues tab with content

The setup button is also visible in the tab bar when there's no .beads folder (always showing an "Issues" tab that leads to the setup CTA).

## 3. GUI: Close issues

In the expanded issue detail (`issueDetail()` in BeadsViewerView), add a **"Close"** button for open issues and a **"Reopen"** button for closed issues.

- Runs `br close <id>` or `bd close <id>` (per preference) with `cwd` as working directory
- Shows spinner during operation
- Reloads issues after completion

## 4. GUI: Add issue

Add a **"+"** button in the `BeadsViewerView` toolbar (next to the filter pills). Clicking opens a popover with:

- Title (required text field)
- Priority (optional picker: P1 High / P2 Medium / P3 Low)
- Type (optional picker: task / bug / feature)
- Description (optional text editor, 3-4 lines)

On submit, runs `br create "title" -p <priority> -t <type> -d "description"` or equivalent `bd create`. Reloads issues after completion.

## 5. BeadsService changes

New methods:
- `findBeadsCLI() -> String?` — finds `bd` or `br` binary based on `@AppStorage("beadsImplementation")`
- `isBdInstalled() -> Bool` / `isBrInstalled() -> Bool` — check each independently
- `findBinary(_ name: String) -> String?` — generic binary finder (common paths)
- `runCLI(arguments:cwd:) -> (exitCode: Int32, stdout: String, stderr: String)` — shell out to the selected beads CLI
- `initBeads(cwd:) -> Result` — runs init
- `createIssue(title:priority:type:description:cwd:) -> Result` — runs create
- `closeIssue(id:cwd:) -> Result` — runs close
- `reopenIssue(id:cwd:) -> Result` — runs reopen

Move bv install logic from BeadsViewerView into BeadsService (shared between Settings and BeadsViewerView).

## 6. CLAUDE.md / AGENTS.md instructions block

Standard block appended during init (adapted per implementation):

```markdown
## Beads Issue Tracking

Use `br` (beads_rust) for issue tracking in this project.
- `br list` — list open issues
- `br ready` — show unblocked issues ready for work
- `br create "title" -p <priority>` — create an issue
- `br close <id>` — close a completed issue
- `br show <id>` — view issue details
```
