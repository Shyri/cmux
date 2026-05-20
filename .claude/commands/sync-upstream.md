---
description: Sync fork/main with manaflow-ai/cmux:main and merge into chatmux
---

# Sync Upstream

Brings `Shyri/cmux:main` up to date with `manaflow-ai/cmux:main`, then merges the new upstream into the personal `chatmux` branch. Designed for the layout we set up on 2026-05-20:

| Branch | Purpose |
|---|---|
| `main` / `fork/main` | Tracks upstream `manaflow-ai/cmux:main` exactly. Never has local commits. |
| `chatmux` / `fork/chatmux` | Personal work (Claude Chat panel, GitLab/diff/notes features) on top of upstream. Should always have `origin/main` as a formal ancestor. |
| `vendor/bonsplit` submodule | Tracks the Bonsplit pointer that upstream cmux references. Mirrored to `Shyri/bonsplit:main` so the parent pointer remains pushable. |

## When to run

- After upstream `manaflow-ai/cmux` ships new commits.
- Before starting new work on `chatmux` so you're not building on a stale base.

## Safety contract

- **Do not push `chatmux` until the user has confirmed a successful build**. The fast-forward at the end is the only "destructive" action and only happens after explicit confirmation.
- Never force-push `main` or `chatmux`.
- Never skip hooks or signing.
- If anything other than `cmux.xcodeproj/project.pbxproj`, tests, or scripts conflicts, **stop and ask the user**. Code-source conflicts in `chatmux`-owned files (Claude Chat panel, GitLab panels, NotesSidebar, diff viewer, etc.) need human judgement.

## Steps

### 1. Sync `main` with upstream

```bash
git fetch origin
git fetch fork
```

If `git rev-list main..origin/main --count` is `0`, `main` is already in sync — skip to step 2.

Otherwise:

```bash
git checkout main
git merge --ff-only origin/main
git push fork main
```

`main` should always fast-forward. If the merge is not fast-forward, **stop** — that means `main` somehow gained local commits and the user needs to deal with that manually.

### 2. Check whether `chatmux` already contains the new upstream

```bash
git fetch origin
git merge-base --is-ancestor origin/main chatmux && echo "already merged" || echo "needs merge"
```

If `already merged` and `git log --oneline chatmux..origin/main` is empty: report "chatmux is already in sync with upstream" and stop.

### 3. Make sure the Bonsplit submodule pointer is reachable

```bash
upstream_bonsplit=$(git ls-tree origin/main vendor/bonsplit | awk '{print $3}')
chatmux_bonsplit=$(git ls-tree chatmux vendor/bonsplit | awk '{print $3}')
```

If `upstream_bonsplit != chatmux_bonsplit`:

1. `cd vendor/bonsplit`
2. Check the commit exists locally: `git log --all --oneline -1 $upstream_bonsplit`. If it doesn't, `git fetch myfork && git fetch` (the submodule's `myfork` remote points at `Shyri/bonsplit`, `origin` may or may not).
3. **Mirror the commit into `Shyri/bonsplit:main`** so future clones of cmux can fetch the submodule pointer cleanly:
   ```bash
   git push myfork $upstream_bonsplit:refs/heads/main
   ```
4. `cd -`

If the commit is **not present anywhere locally** and `Shyri/bonsplit` doesn't have it either, you need to add the upstream `manaflow-ai/bonsplit` as a remote and fetch from there. **Stop and ask the user before doing that** — it's a one-off setup that should outlive this command.

### 4. Create a temporary merge branch from `chatmux`

```bash
suffix=$(date +%Y%m%d-%H%M%S)
git checkout -b "chatmux-merge-$suffix" chatmux
```

Using a temp branch means we can always abort with `git merge --abort` (or `git reset --hard chatmux`) without touching the user's `chatmux`.

### 5. Merge `origin/main` into the temp branch

```bash
git merge --no-commit --no-ff origin/main
```

If the merge reports `Already up to date`, the temp branch was already at upstream — skip to step 8.

If it reports conflicts:

1. Examine `git diff --name-only --diff-filter=U`. The expected files are:
   - `cmux.xcodeproj/project.pbxproj` (always — the auto-resolver handles it)
   - Test files under `cmuxTests/` (usually safe to keep ours; chatmux-owned tests evolve faster than upstream)
   - CI configs (`.circleci/config.yml`, `.github/workflows/*.yml`) and scripts (`scripts/*.sh`) — usually keep ours

2. **If any conflicted file is under `Sources/`, `Packages/`, `Resources/`, or somewhere that holds real product logic**, stop and surface the list to the user. Don't auto-resolve product code with `--ours`; it could silently drop something the user wanted from upstream.

3. Otherwise, run the helper:
   ```bash
   python3 scripts/sync-upstream-resolve.py
   ```
   The helper:
   - Resolves `cmux.xcodeproj/project.pbxproj` markers (keeps upstream additions, dedupes IDs / package-reference blocks).
   - Marks every other conflict as "keep ours".
   - Re-checks that nothing is unmerged afterward and that the pbxproj has no duplicate IDs or broken references.
   Exit code `0` = safe to continue; `1` = something the helper couldn't handle — stop and surface its stderr.

### 6. Make sure the submodule pointer is the merged one

```bash
git submodule update vendor/bonsplit
git ls-tree HEAD vendor/bonsplit
```

The pointer reported by `ls-tree HEAD` should match `upstream_bonsplit` from step 3. If it doesn't, `cd vendor/bonsplit && git checkout $upstream_bonsplit && cd - && git add vendor/bonsplit`.

### 7. Finish the merge commit

```bash
git commit --no-edit
```

Don't amend or rewrite the message. The default `Merge remote-tracking branch 'origin/main' into chatmux-merge-…` is what git history needs to recognise the merge.

Verify:

```bash
git merge-base --is-ancestor origin/main HEAD && echo "OK: upstream is now ancestor"
git log --oneline --cherry-pick --right-only HEAD...origin/main | wc -l  # expect 0
```

### 8. Push the temp branch and ask the user to build

```bash
git push fork "chatmux-merge-$suffix"
```

Surface the branch name to the user and ask them to run their build (`./scripts/reload.sh --tag chatmux-merge-…` or similar). **Wait for explicit confirmation that the build succeeded before continuing.**

If the build fails, debug from the temp branch (the user's `chatmux` is still untouched).

### 9. Fast-forward `chatmux` and clean up

Once the user confirms the build works:

```bash
git checkout chatmux
git merge --ff-only "chatmux-merge-$suffix"
git push fork chatmux
git branch -d "chatmux-merge-$suffix"
git push fork --delete "chatmux-merge-$suffix"
```

### 10. Report

Summarise:
- `main` now at: `<SHA> <subject>`
- `chatmux` now at: `<merge-SHA>`
- Bonsplit pointer: `<sha>`
- How many genuine new upstream commits landed (= `git rev-list <previous chatmux>..chatmux --count`).

## Notes

- The auto-resolve strategy for `--ours` works because `chatmux` is the source of truth for everything that's not upstream's responsibility. If you ever want to bring an upstream change that touched a file `chatmux` also touched, you have to do it manually — the helper will not second-guess that decision.
- After the merge, the personal MCP/bashes files (`Sources/Panels/McpManagerPopover.swift`, `Sources/Panels/BackgroundShellsPopover.swift`, `Sources/ClaudeChat/McpHealthProber.swift`, `Sources/ClaudeChat/McpServerCatalog.swift`) and the focus-regain fix (`Sources/CmuxLifecycleEventPublishing.swift`) should still be there. If they're missing, something went wrong with the merge — restore from `chatmux` and investigate.
- Don't run this command in a worktree where the submodules aren't fully checked out. The submodule pointer step depends on `git ls-tree` returning real refs.
