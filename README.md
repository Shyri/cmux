<h1 align="center">Chatmux</h1>

<p align="center"><strong>The terminal where your AI agent, your code review, and your git workflow live in one window.</strong></p>

<p align="center">
A personal, opinionated fork of <a href="https://github.com/manaflow-ai/cmux">cmux</a> — the Ghostty-based macOS terminal for AI coding agents — with a first-class in-app Claude chat, a GitLab workflow sidebar, and a SourceTree-style working-copy view built in.
</p>

<p align="center">
  <a href="#why-chatmux-exists">Why</a> ·
  <a href="#what-you-get">What you get</a> ·
  <a href="#a-day-with-chatmux">A day with Chatmux</a> ·
  <a href="#chatmux-vs-upstream-cmux">vs. cmux</a> ·
  <a href="#install-from-source">Install</a> ·
  <a href="https://github.com/manaflow-ai/cmux">Upstream cmux</a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="Chatmux — a Ghostty terminal with vertical tabs, an in-app agent chat, and a git workflow sidebar" width="900" />
</p>

---

## Why Chatmux exists

Working with an AI coding agent means living in three places at once: the **terminal** where the agent runs, the **chat** where you steer it, and the **git tooling** where you review what it did. Every context switch — alt-tabbing to a browser for the MR, flipping to SourceTree to see the diff, hunting for which branch the agent is on — is a tax on your attention.

[cmux](https://github.com/manaflow-ai/cmux) already solved the first part beautifully: a fast Ghostty terminal with vertical tabs, per-agent notification rings, an in-app browser, and session restore. **Chatmux collapses the other two into the same window.**

The agent chat is a native panel next to your terminal — not a browser tab, not a separate app. The code review lives in a GitLab sidebar scoped to whatever project the workspace is in. The "what did the agent just change?" question is answered by a working-copy view that's always one glance away. No alt-tab. No losing your place. One window, the whole loop.

If you drive Claude Code all day and your team runs on GitLab, this is the terminal built for that.

## What you get

Everything in [upstream cmux](https://github.com/manaflow-ai/cmux) — notification rings, in-app browser, vertical + horizontal tabs, SSH, Claude Code Teams, session restore, the cmux CLI/socket API — **plus three surfaces the fork adds:**

### 🗨️ An in-app Claude chat panel

A native Claude SDK panel that lives inside any pane. It picks up the pane's working directory, streams responses, and journals every conversation to disk so chats survive restarts. Open it with the tab-bar action `cmux.newClaudeChat`.

- **Model & effort pickers in the composer** — switch model and reasoning effort per message, no dialog, no relaunch.
- **Live todos banner** — `TaskCreate` / `TaskUpdate` events from Claude Code roll up into a to-do list pinned above the transcript, so you always see the plan and the progress.
- **Worktree-aware branch chip** — the chat header shows the working directory's branch and follows `EnterWorktree` in real time, so you never confuse which branch the agent is on.
- **Mermaid diagrams, rendered** — fenced ` ```mermaid ` blocks render as real diagrams inline, with zoom, scroll, and a pop-out floating window for the big ones.
- **Readable at any size** — zoom the chat font up or down from the header (with a touch of extra line spacing), and it's remembered across sessions.
- **Resume with a hydrated transcript** — open a session from the Sessions panel and the full history renders instantly, before the runner is even reattached. No empty-state flash.
- **Cancel queued + rebuild shells on resume** — kill queued messages before the agent reaches them; on resume, background shells are recreated from the transcript so detached commands keep tailing where you left off.
- **Pending changes, always visible** — a live working-tree summary sits beside the chat, and a resizable divider + full-width composer let you give the diff or the input as much room as you want.
- **Copyable everything** — per-bubble copy on hover, a copyable session id, and a copy button on every code block.
- **MCP & Background Shells popovers** — register and health-check MCP servers, and browse/peek/resume the detached shells the agent launched, straight from the title bar.

Under the hood: a permission-rules engine (which tools run automatically vs. ask first), a per-chat slash-command registry, a live status-line runner, and on-disk session history.

<!-- Screenshots — uncomment once captured:
<p align="center">
  <img src="./docs/assets/chatmux-chat.png" alt="Claude chat panel: model/effort pickers, todos banner, branch chip" width="900" />
  <img src="./docs/assets/chatmux-mermaid.png" alt="A Mermaid diagram rendered inline in the chat" width="900" />
</p>
-->

### 🦊 A GitLab workflow sidebar

A right-sidebar panel scoped to the workspace's GitLab project. It uses your local `glab` / `git` config — no extra credentials.

- **Merge Requests** with assignee/author filters, opening into a **three-way diff viewer** with inline discussion threads and always-correct base/target SHAs.
- **Issues** with filters (assignee, author, labels, milestone) that survive panel toggles and workspace switches.
- **Pipelines** — real-time status, color-coded by stage, jump straight to a failing job.
- **Releases** — browse them inline without leaving the terminal.
- **State that follows you** — the active sub-tab (MRs vs. Issues vs. Pipelines) is remembered per workspace, so switching away and back lands you exactly where you were.

<!-- Screenshots — uncomment once captured. Recorded against the public
     gitlab-org/gitlab-runner (MRs / Issues / Releases) and inkscape/inkscape
     (Pipelines, for the mixed pass/fail colors) so no private data leaks:
<table>
<tr>
  <td width="50%"><img src="./docs/assets/gitlab-mrs.png" alt="GitLab Merge Requests and three-way diff with inline discussions" width="100%" /></td>
  <td width="50%"><img src="./docs/assets/gitlab-issues.png" alt="GitLab Issues with assignee/label/milestone filters" width="100%" /></td>
</tr>
<tr>
  <td width="50%"><img src="./docs/assets/gitlab-pipelines.png" alt="GitLab Pipelines color-coded by stage" width="100%" /></td>
  <td width="50%"><img src="./docs/assets/gitlab-releases.png" alt="GitLab Releases browsed inline" width="100%" /></td>
</tr>
</table>
-->

### ✅ A SourceTree-style "Changes" view

A working-copy panel that answers "what's changed here?" at a glance — grouped into **Staged / Modified / Untracked**, with the **current branch** shown up top. Click any file to open its working-tree diff in the standalone viewer. It's the git-status pane you keep open while the agent works.

**Both the GitLab sidebar and the Changes view open as panes/tabs** — exactly like Files and Find — via the split button in the sidebar header or the command palette (*Open GitLab as Pane*, *Open Changes as Pane*).

<!-- Screenshot — uncomment once captured:
<p align="center">
  <img src="./docs/assets/chatmux-changes.png" alt="SourceTree-style Changes view grouped by Staged / Modified / Untracked with the current branch" width="900" />
</p>
-->

### 🧰 …and the quality-of-life extras

- **Standalone Git diff viewer** — a diff window for any commit, branch, or working tree, with side-by-side and three-way views, a custom LCS diff engine, and syntax highlighting for Swift / TypeScript / Markdown and more. Shared with the GitLab MR discussions viewer.
- **Workspace Notes sidebar** — per-workspace markdown notes that travel with the workspace and auto-archive on close (never silently dropped), plus a Notes Manager window to browse and restore archived notes. Toggle with `cmux.toggleNotes`.
- **Session presets** — save the current pane / surface / terminal / browser layout as a named preset and re-instantiate it later (`File → Save Session as Preset…`). Scoped per bundle id, so Chatmux and cmux keep independent collections.
- **Open in Sourcetree** — `cmux.openInSourcetree` opens the focused pane's working directory in [Sourcetree](https://www.sourcetreeapp.com/).
- **Side-by-side install** — installs as `Chatmux.app` with its own bundle id (`com.cmuxterm.app.fork`) so it runs right next to upstream cmux, with independent workspaces, snapshots, presets, notes, and TCC permissions.

## A day with Chatmux

- **Kick off a change.** Open a Claude chat in a pane, pick your model and effort in the composer, and describe the task. The todos banner fills in as the agent plans; the branch chip tells you it's working on the right worktree.
- **Watch it work.** The Changes view on the right ticks up file by file — Staged, Modified, Untracked — while the pending-changes summary beside the chat shows the shape of the diff. When the agent draws a Mermaid diagram to explain its plan, you actually see it.
- **Review without leaving.** Flip the sidebar to GitLab, open the MR, and read the three-way diff with the discussion threads inline. Click a changed file in the Changes view to pull up its working-tree diff in the standalone viewer.
- **Step away and come back.** Close the laptop. On resume, the transcript hydrates instantly, background shells rebuild themselves and keep tailing, and your GitLab sub-tab and issue filters are exactly where you left them.

## Chatmux vs. upstream cmux

Chatmux is a **superset** — nothing from cmux is removed. It adds the surfaces that turn the terminal into a full agent + review loop.

| | Upstream cmux | Chatmux |
|---|:---:|:---:|
| Ghostty terminal, vertical + horizontal tabs, splits | ✅ | ✅ |
| Per-agent notification rings, in-app browser, SSH, session restore | ✅ | ✅ |
| Claude Code Teams, cmux CLI / socket API | ✅ | ✅ |
| **In-app Claude chat panel** (pickers, todos, MCP, background shells) | — | ✅ |
| **Mermaid rendering + chat font zoom** | — | ✅ |
| **GitLab sidebar** (MRs, issues, pipelines, releases, three-way diff) | — | ✅ |
| **SourceTree-style Changes / git-status view with branch** | — | ✅ |
| **Open GitLab / Changes as panes** | — | ✅ |
| **Standalone diff viewer, Workspace Notes, Session presets, Open in Sourcetree** | — | ✅ |
| Distributed as a signed DMG | ✅ | Build from source |

## Inherited from cmux

All of the reasons to use cmux in the first place come along unchanged. A few of them:

<table>
<tr>
<td width="60%"><img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="Vertical and horizontal tabs with splits" width="100%" /></td>
<td width="40%" valign="middle"><h3>Vertical + horizontal tabs and splits</h3>A tab layout that scales to a dozen agents without losing your place.</td>
</tr>
<tr>
<td width="40%" valign="middle"><h3>Per-agent notification rings</h3>Every workspace shows when its agent needs you — no polling, no missed prompts.</td>
<td width="60%"><img src="./docs/assets/notification-rings.png" alt="Per-agent notification rings" width="100%" /></td>
</tr>
<tr>
<td width="60%"><img src="./docs/assets/built-in-browser.png" alt="Built-in browser" width="100%" /></td>
<td width="40%" valign="middle"><h3>In-app browser</h3>Preview localhost, read docs, or open the deploy — without leaving the terminal.</td>
</tr>
<tr>
<td width="40%" valign="middle"><h3>SSH & Claude Code Teams</h3>Drive remote hosts and shared team sessions with the same UI.</td>
<td width="60%"><img src="./docs/assets/ssh.png" alt="SSH support" width="100%" /></td>
</tr>
</table>

See the [upstream README](https://github.com/manaflow-ai/cmux/blob/main/README.md) for the full tour.

## Install (from source)

Chatmux isn't published as a DMG — build and install it with the fork script.

```bash
# Clone with submodules
git clone --recurse-submodules https://github.com/Shyri/cmux.git
cd cmux

# One-time setup (fetches the Ghostty submodule, GhosttyKit, etc.)
./scripts/setup.sh

# Build Release + install to /Applications/Chatmux.app + launch
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

**Why the `rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1` prefix?** Locally we run Zig 0.16, but Ghostty requires 0.15.2. Skipping the Zig build forces the script to use the prebuilt `GhosttyKit.xcframework` from `manaflow-ai/ghostty` releases; clearing `zig-pkg/` keeps the build key clean so the prebuilt cache hits.

`install-fork.sh` signs ad-hoc with a distinct bundle id (`com.cmuxterm.app.fork`) and installs to `/Applications/Chatmux.app`, so it runs alongside upstream cmux. Override with `--name`, `--bundle-id`, or `--dest` for a different identity (e.g. a staging build). Keeping the bundle id stable is what preserves your macOS Documents / App Management permissions and all bundle-id-keyed state (workspaces, snapshots, presets, notes, MCP config) across reinstalls.

## Keyboard shortcuts

All upstream cmux shortcuts work unchanged — see the [upstream table](https://github.com/manaflow-ai/cmux/blob/main/README.md#keyboard-shortcuts). Chatmux-only shortcuts are configurable in **Settings → Keyboard Shortcuts** and surface in `~/.config/cmux/cmux.json` like every other cmux shortcut.

## Credits

Chatmux is a fork of [cmux](https://github.com/manaflow-ai/cmux) by [Manaflow](https://manaflow.com). The terminal engine and every upstream feature are theirs — please **star and support the original project**. This fork just adds the chat, review, and git surfaces I wanted for my own workflow.

## License

Same as upstream: [GPL-3.0-or-later](LICENSE).
