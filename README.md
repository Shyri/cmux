<h1 align="center">Chatmux</h1>
<p align="center">A personal fork of <a href="https://github.com/manaflow-ai/cmux">cmux</a> with first-class Claude integration, GitLab workflow tooling, and other quality-of-life features.</p>

<p align="center">
  <a href="#install-from-source">Install from source</a> · <a href="#what-this-fork-adds">What this fork adds</a> · <a href="#keeping-up-with-upstream">Sync with upstream</a> · <a href="https://github.com/manaflow-ai/cmux">Upstream cmux</a>
</p>

---

Chatmux is built on top of [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) — a Ghostty-based macOS terminal with vertical tabs and notifications for AI coding agents. Everything documented in the upstream [README](https://github.com/manaflow-ai/cmux/blob/main/README.md) still applies: notification rings, in-app browser, vertical+horizontal tabs, SSH, Claude Code Teams, session restore, the cmux CLI/socket API, etc.

This document covers only what Chatmux adds on top.

## What this fork adds

### Claude Chat panel

In-app Claude SDK panel that lives inside any pane — picks up the workspace's working directory, streams responses, and persists conversation history per surface.

- MCP integration: built-in **MCP Manager** popover to register/manage MCP servers and a health prober that surfaces server status inline
- Slash command registry: define your own per-chat slash commands
- Status line runner: long-running tasks render a live status line in the chat header
- Session history: every chat is journalled to disk and can be resumed across cmux restarts
- Permission-rules engine: configure which tools the chat can invoke automatically vs. ask first

Tab-bar built-in action `cmux.newClaudeChat` opens a new Claude Chat in the focused pane.

### GitLab integration

Right-sidebar panel scoped to the workspace's GitLab project:

- **Merge Requests** list with assignee/author filters and one-click open
- **Issues** list with the same filter system, backed by `GitLabIssueFiltersStore`
- **Pipelines** list with status indicators
- **Releases** list
- **MR Discussions** viewer with three-way diff support (`MRDiscussions.swift`)
- Diff refs and merged-tree stores so the diff viewer always knows the right base/target SHAs

Uses your local `glab` / `git` config — no extra credentials needed.

### Git diff viewer

Standalone diff window for any commit, branch, or working tree (`GitDiffWindow.swift`):

- Side-by-side `DiffCodeTextView` and three-way `DiffThreeWayCodeTextView`
- Custom `LCSDiff` engine and `SyntaxHighlighter` for Swift, TypeScript, Markdown, etc.
- Shared with the GitLab MR discussions viewer

### Workspace Notes sidebar

Per-workspace markdown notes that travel with the workspace:

- Sidebar slot mounted next to the GitLab panel (right sidebar)
- Auto-archive on workspace close — notes are never silently dropped (see `TabManager.closeWorkspace` safety net)
- Standalone **Notes Manager** window (`WorkspaceNotesManagerWindowController`) to browse and restore archived notes across all workspaces
- Tab-bar built-in action `cmux.toggleNotes` to flip the sidebar from the keyboard or a custom command

### Session presets

Save the current session layout (panes, surfaces, terminals, browser URLs, sidebar state) as a named preset, then re-instantiate it later:

- Save: `File → Save Session as Preset…` (or the command palette)
- Load: `File → Load Preset → …`
- Update: `File → Update Current Preset`
- Storage is scoped per-bundle-id so cmux and Chatmux keep independent preset collections (`SessionPresetSchema.defaultDirectoryURL`)

### MCP Manager + Background Shells popovers

Two popovers reachable from the title bar:

- **MCP Manager** — discover, enable, disable, and health-check MCP servers used by the Claude chat
- **Background Shells** — browse detached shells launched by the chat / surface API, peek at their output, and resume them into a visible surface

### Open in Sourcetree

New tab-bar built-in action `cmux.openInSourcetree` next to `openInFinder` and `openInIDE`. Opens the focused pane's working directory in [Atlassian Sourcetree](https://www.sourcetreeapp.com/) (falls back to a beep if Sourcetree isn't installed at `/Applications/Sourcetree.app`).

Wire it into your own button layout in `~/.config/cmux/cmux.json` or rely on the default tab bar.

### Self-install script

`scripts/install-fork.sh` builds the Release configuration, signs ad-hoc with a distinct bundle id, and copies the bundle to `/Applications/Chatmux.app` so it runs side-by-side with upstream cmux:

```bash
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

Default identity:

| Field | Value |
|---|---|
| App name | `Chatmux` |
| Bundle id | `com.cmuxterm.app.fork` |
| Install path | `/Applications/Chatmux.app` |

Override with `--name`, `--bundle-id`, or `--dest` if you want a different identity (e.g. a staging build). The bundle id pinning via `codesign -i <bundle-id>` is critical for stable macOS TCC permissions — without it, Documents/App Management permissions re-prompt every launch.

Workspaces, session snapshots, presets, notes, MCP config, and TCC grants are all keyed by `CFBundleIdentifier`, so they persist across re-installs as long as you keep the bundle id the same.

### `/sync-upstream` slash command

A custom Claude Code slash command (in `.claude/commands/`) automates the chatmux ↔ upstream merge dance:

- Fast-forwards `main` to `manaflow-ai/cmux:main`
- Mirrors the matching `vendor/bonsplit` submodule pointer to your bonsplit fork
- Creates a temp `chatmux-merge-<timestamp>` branch and merges upstream into it
- Auto-resolves `cmux.xcodeproj/project.pbxproj` conflicts by combining both sides + deduping by ID
- Stops and surfaces any conflict in `Sources/`, `Packages/`, or `Resources/` for human resolution
- Pushes the temp branch and waits for a build confirmation before fast-forwarding `chatmux`

See `.claude/commands/sync-upstream.md` for the full workflow and `scripts/sync-upstream-resolve.py` for the pbxproj helper.

## Install (from source)

Chatmux is not published as a DMG. Build and install with the fork script:

```bash
# Clone with submodules
git clone --recurse-submodules https://github.com/Shyri/cmux.git
cd cmux

# One-time setup (fetches Ghostty submodule, GhosttyKit, etc.)
./scripts/setup.sh

# Build Release + install to /Applications/Chatmux.app + launch
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

Why the `rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1` prefix? Locally we run Zig 0.16, but Ghostty requires 0.15.2. Skipping the Zig build forces the script to use the prebuilt GhosttyKit.xcframework from `manaflow-ai/ghostty` releases. The `zig-pkg/` cleanup keeps the build key clean so the prebuilt cache hit works.

## Keeping up with upstream

```bash
# Inside a Claude Code session in this repo:
/sync-upstream
```

The slash command handles the full merge workflow including conflict triage. See [What this fork adds → /sync-upstream](#sync-upstream-slash-command).

For manual merges, follow the same steps in `.claude/commands/sync-upstream.md`.

## Keyboard shortcuts

All upstream cmux shortcuts work unchanged. See the [upstream README](https://github.com/manaflow-ai/cmux/blob/main/README.md#keyboard-shortcuts) for the full table. Chatmux-only shortcuts are configurable via Settings → Keyboard Shortcuts and surface in `~/.config/cmux/cmux.json` like every other cmux shortcut.

## Credits

Chatmux is a fork of [cmux](https://github.com/manaflow-ai/cmux) by [Manaflow](https://manaflow.com). All upstream features and the terminal engine are theirs — please star and support the original project.

## License

Same as upstream: [GPL-3.0-or-later](LICENSE).
