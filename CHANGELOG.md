# Changelog

## v0.2 — 2026-02-18

### New Features
- **OpenCode plugin support** — install/uninstall hooks for [OpenCode](https://opencode.ai/) alongside Claude Code
- **SessionStart hook** — agents register immediately on session start instead of waiting for the first tool use
- **Follow agent mode** — automatically switches focus to agents waiting for input or permission
- **Pinned sidebar folders** — pin project folders in the sidebar so they stay visible even when no agents are running
- **Toolbar actions** — split tmux panes, send `/clear` and `/compact` commands from the toolbar
- **Event log panel** — view recent hook events for the selected agent session
- **CLI version tracking** — Settings and Setup Wizard now show when the CLI binary needs updating

### Improvements
- Moved `displayTitle` logic into the `Agent` model for reuse
- Auto-detect tmux session name as fallback when `WORKFORCE_SESSION` is not set
- Launch tmux sessions with direct argv instead of shell escaping (fixes prompts with special characters)
- Codesign the CLI binary with Hardened Runtime during the Xcode build phase
- More robust workforce command detection in hook install/uninstall (matches binary name instead of substring)

### Housekeeping
- Removed `build/` directory from git tracking
- Updated README to reflect OpenCode support

## v0.1 — 2026-02-15

Initial release.
