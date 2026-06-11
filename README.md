<h1 align="center">Chatmux</h1>
<p align="center">A personal fork of <a href="https://github.com/manaflow-ai/cmux">cmux</a> with first-class Claude integration, GitLab workflow tooling, and other quality-of-life features.</p>

<p align="center">
  <a href="#what-is-chatmux">What is it?</a> ·
  <a href="#claude-chat">Claude Chat</a> ·
  <a href="#gitlab-workflow">GitLab workflow</a> ·
  <a href="#install-from-source">Install from source</a> ·
  <a href="https://github.com/manaflow-ai/cmux">Upstream cmux</a>
</p>

<p align="center">
  <img src="./docs/assets/chatmux-hero.png" alt="Chatmux screenshot" width="900" />
</p>

---

## What is Chatmux?

Chatmux is a personal fork of [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) — a Ghostty-based macOS terminal with vertical tabs and notifications for AI coding agents. Everything documented in the upstream [README](https://github.com/manaflow-ai/cmux/blob/main/README.md) still applies: notification rings, in-app browser, vertical+horizontal tabs, SSH, Claude Code Teams, session restore, the cmux CLI/socket API.

On top of that, Chatmux adds two big surfaces:

- **An in-app Claude Chat panel** that lives next to your terminal — model/effort pickers, live todos, worktree-aware, MCP and background shells built in.
- **A GitLab workflow sidebar** scoped to the workspace's project — merge requests, issues, pipelines, and releases, with a real three-way diff viewer for review.

Plus smaller quality-of-life additions: standalone Git diff viewer, Workspace Notes sidebar, Session presets, Open in Sourcetree, and a side-by-side install.

## Claude Chat

In-app Claude SDK panel that lives inside any pane — picks up the workspace's working directory, streams responses, persists conversation history per surface, and is journalled to disk so chats survive cmux restarts. Open via the tab-bar built-in action `cmux.newClaudeChat`.

<table>
<tr>
<td width="40%" valign="middle">
<h3>Model & effort pickers</h3>
Switch model and reasoning effort directly from the composer. No settings dialog, no relaunch — every message uses what's currently selected.
</td>
<td width="60%">
<img src="./docs/assets/chatmux-pickers.png" alt="Model and effort pickers in the composer" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Live todos banner</h3>
<code>TaskCreate</code> / <code>TaskUpdate</code> events from Claude Code 2.x roll up into a live to-do list pinned above the transcript. You always see what the agent has planned and how far in it is.
</td>
<td width="60%">
<img src="./docs/assets/chatmux-todos.gif" alt="Todos banner accumulating from TaskCreate/TaskUpdate" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Worktree-aware</h3>
A git branch chip in the chat header shows the working directory's branch. When a tool calls <code>EnterWorktree</code>, the chip follows in real time so you never confuse which branch the agent is operating on.
</td>
<td width="60%">
<img src="./docs/assets/chatmux-branch-chip.gif" alt="Branch chip following EnterWorktree" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Copyable everything</h3>
Per-bubble copy on hover, copyable session id in the header, and copy icons on every fenced code block. Lifting a snippet or sharing a session is one click.
</td>
<td width="60%">
<img src="./docs/assets/chatmux-copy.png" alt="Per-bubble and per-code-block copy buttons" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Resume with hydrated transcript</h3>
Open a session from the upstream Sessions panel and the full transcript renders instantly — before the Claude runner is even reattached. No empty-state flash, no "loading…" while you scroll history.
</td>
<td width="60%">
<img src="./docs/assets/chatmux-sessions-hydrate.png" alt="Sessions panel opening with hydrated transcript" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Cancel queued + rebuild shells on resume</h3>
Cancel queued user messages straight from the transcript before the agent gets to them. On resume, background shells are recreated from the transcript so detached commands still tail their output where you left them.
</td>
<td width="60%">
<img src="./docs/assets/chatmux-queue-shells.gif" alt="Cancelling a queued message and rebuilding shells on resume" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Pending changes summary</h3>
A live summary of the working tree's pending changes lives alongside the chat so you always know what the agent has touched without flipping to Sourcetree or <code>git status</code>.
</td>
<td width="60%">
<img src="./docs/assets/chatmux-pending.png" alt="Pending changes summary" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>MCP & Background Shells popovers</h3>
Built-in <strong>MCP Manager</strong> (register, enable, health-check MCP servers) and <strong>Background Shells</strong> (browse detached shells launched by the chat, peek at output, resume into a visible surface) reachable from the title bar.
</td>
<td width="60%">
<img src="./docs/assets/chatmux-mcp-shells.png" alt="MCP Manager and Background Shells popovers" width="100%" />
</td>
</tr>
</table>

Plus, under the hood:

- **Permission-rules engine** — configure which tools the chat can invoke automatically vs. ask first.
- **Slash command registry** — define your own per-chat slash commands.
- **Status line runner** — long-running tasks render a live status line in the chat header.
- **Session history** — every chat is journalled to disk and can be resumed across cmux restarts.

## GitLab workflow

Right-sidebar panel scoped to the workspace's GitLab project. Uses your local `glab` / `git` config — no extra credentials needed.

> Screenshots below were recorded against the public [`gitlab-org/gitlab-runner`](https://gitlab.com/gitlab-org/gitlab-runner) project so they don't leak data from any private workspace.

<table>
<tr>
<td width="40%" valign="middle">
<h3>Merge Requests + discussions + diff</h3>
MR list with assignee/author filters. Click into a three-way diff viewer with inline discussion threads — the diff refs store always knows the right base/target SHAs.
</td>
<td width="60%">
<img src="./docs/assets/gitlab-mrs.png" alt="GitLab Merge Requests panel and diff viewer" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Issues with filters</h3>
Issues list backed by <code>GitLabIssueFiltersStore</code> — filter by assignee, author, labels, milestone. Filters survive panel toggles and workspace switches.
</td>
<td width="60%">
<img src="./docs/assets/gitlab-issues.png" alt="GitLab Issues panel with filters" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Pipelines</h3>
Real-time pipeline status for the workspace's project, color-coded by stage. Jump straight to a failing job's log.
</td>
<td width="60%">
<img src="./docs/assets/gitlab-pipelines.png" alt="GitLab Pipelines panel" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Releases</h3>
Browse the project's releases inline without leaving cmux.
</td>
<td width="60%">
<img src="./docs/assets/gitlab-releases.png" alt="GitLab Releases panel" width="100%" />
</td>
</tr>
</table>

## Other quality-of-life

- **Git diff viewer** — standalone diff window for any commit, branch, or working tree (`GitDiffWindow.swift`). Side-by-side `DiffCodeTextView`, three-way `DiffThreeWayCodeTextView`, custom `LCSDiff` engine and `SyntaxHighlighter` for Swift / TypeScript / Markdown / etc. Shared with the GitLab MR discussions viewer.
- **Workspace Notes sidebar** — per-workspace markdown notes that travel with the workspace, auto-archive on close (notes are never silently dropped — see `TabManager.closeWorkspace`), and a standalone Notes Manager window (`WorkspaceNotesManagerWindowController`) to browse and restore archived notes across all workspaces. Toggle via `cmux.toggleNotes`.
- **Session presets** — save the current pane / surface / terminal / browser layout as a named preset and re-instantiate later: `File → Save Session as Preset…`, `File → Load Preset → …`, `File → Update Current Preset`. Storage is scoped per bundle id (`SessionPresetSchema.defaultDirectoryURL`) so cmux and Chatmux keep independent collections.
- **Open in Sourcetree** — `cmux.openInSourcetree` tab-bar action opens the focused pane's working directory in [Sourcetree](https://www.sourcetreeapp.com/) (falls back to a beep if not installed). Wire it into your own button layout in `~/.config/cmux/cmux.json` or rely on the default tab bar.
- **Side-by-side install** — `scripts/install-fork.sh` signs ad-hoc with a distinct bundle id (`com.cmuxterm.app.fork`) and copies the bundle to `/Applications/Chatmux.app` so it runs alongside upstream cmux. Override with `--name`, `--bundle-id`, or `--dest` for a different identity (e.g. a staging build). Bundle-id pinning via `codesign -i <bundle-id>` is critical for stable macOS TCC permissions — without it, Documents/App Management permissions re-prompt every launch. Workspaces, session snapshots, presets, notes, MCP config, and TCC grants are all keyed by `CFBundleIdentifier`, so they persist across reinstalls as long as you keep the bundle id the same.

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

## Keyboard shortcuts

All upstream cmux shortcuts work unchanged. See the [upstream README](https://github.com/manaflow-ai/cmux/blob/main/README.md#keyboard-shortcuts) for the full table. Chatmux-only shortcuts are configurable via Settings → Keyboard Shortcuts and surface in `~/.config/cmux/cmux.json` like every other cmux shortcut.

## Credits

Chatmux is a fork of [cmux](https://github.com/manaflow-ai/cmux) by [Manaflow](https://manaflow.com). All upstream features and the terminal engine are theirs — please star and support the original project.

## License

Same as upstream: [GPL-3.0-or-later](LICENSE).
