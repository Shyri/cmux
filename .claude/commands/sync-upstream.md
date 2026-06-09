---
description: Sync fork/upstream-main with manaflow-ai/cmux:main and merge into main
---

# Sync Upstream

Brings `Shyri/cmux:upstream-main` up to date with `manaflow-ai/cmux:main`, then merges the new upstream into the personal `main` branch (where ChatMux work lives). Designed for the layout in place since 2026-06-09:

| Branch | Purpose |
|---|---|
| `upstream-main` / `fork/upstream-main` | Tracks upstream `manaflow-ai/cmux:main` exactly. Never has local commits. |
| `main` / `fork/main` | Personal work (Claude Chat panel, GitLab/diff/notes features) on top of upstream. Default branch of the fork. Should always have `origin/main` as a formal ancestor. |
| `vendor/bonsplit` submodule | Tracks the Bonsplit pointer that upstream cmux references. Mirrored to `Shyri/bonsplit:main` so the parent pointer remains pushable. |

`origin` is the upstream `manaflow-ai/cmux`; `fork` is `Shyri/cmux`.

## When to run

- After upstream `manaflow-ai/cmux` ships new commits.
- Before starting new work on `main` so you're not building on a stale base.

## Safety contract

- **Do not push `main` until the user has confirmed a successful build**. The fast-forward at the end is the only "destructive" action and only happens after explicit confirmation.
- Never force-push `main` or `upstream-main`.
- Never skip hooks or signing.
- If anything other than `cmux.xcodeproj/project.pbxproj`, tests, or scripts conflicts, **stop and ask the user**. Code-source conflicts in fork-owned files (Claude Chat panel, GitLab panels, NotesSidebar, diff viewer, etc.) need human judgement.

## Steps

### 1. Sync `upstream-main` with upstream

```bash
git fetch origin
git fetch fork
```

If `git rev-list upstream-main..origin/main --count` is `0`, `upstream-main` is already in sync — skip to step 2.

Otherwise:

```bash
git checkout upstream-main
git merge --ff-only origin/main
git push fork upstream-main
```

`upstream-main` should always fast-forward. If the merge is not fast-forward, **stop** — that means `upstream-main` somehow gained local commits and the user needs to deal with that manually.

### 2. Check whether `main` already contains the new upstream

```bash
git fetch origin
git merge-base --is-ancestor origin/main main && echo "already merged" || echo "needs merge"
```

If `already merged` and `git log --oneline main..origin/main` is empty: report "main is already in sync with upstream" and stop.

### 3. Make sure the Bonsplit submodule pointer is reachable

```bash
upstream_bonsplit=$(git ls-tree origin/main vendor/bonsplit | awk '{print $3}')
main_bonsplit=$(git ls-tree main vendor/bonsplit | awk '{print $3}')
```

If `upstream_bonsplit != main_bonsplit`:

1. `cd vendor/bonsplit`
2. Check the commit exists locally: `git log --all --oneline -1 $upstream_bonsplit`. If it doesn't, `git fetch myfork && git fetch` (the submodule's `myfork` remote points at `Shyri/bonsplit`, `origin` may or may not).
3. **Mirror the commit into `Shyri/bonsplit:main`** so future clones of cmux can fetch the submodule pointer cleanly:
   ```bash
   git push myfork $upstream_bonsplit:refs/heads/main
   ```
4. `cd -`

If the commit is **not present anywhere locally** and `Shyri/bonsplit` doesn't have it either, you need to add the upstream `manaflow-ai/bonsplit` as a remote and fetch from there. **Stop and ask the user before doing that** — it's a one-off setup that should outlive this command.

### 4. Create a temporary merge branch from `main`

```bash
suffix=$(date +%Y%m%d-%H%M%S)
git checkout -b "main-merge-$suffix" main
```

Using a temp branch means we can always abort with `git merge --abort` (or `git reset --hard main`) without touching the user's `main`.

### 5. Merge `origin/main` into the temp branch

```bash
git merge --no-commit --no-ff origin/main
```

If the merge reports `Already up to date`, the temp branch was already at upstream — skip to step 8.

If it reports conflicts, resolve them **manually** and `git add` each file as you go. Past sync experience (2026-06-09): the auto-resolver helper destroys upstream additions in big files like `Sources/Workspace.swift` and the dedup in `cmux.xcodeproj/project.pbxproj` drops fork-only entries. The reliable strategy is:

1. Examine `git diff --name-only --diff-filter=U`. Expected files:
   - `cmux.xcodeproj/project.pbxproj` (always — needs a union merge, see below)
   - `Resources/Localizable.xcstrings` (always — needs a JSON merge, see below)
   - Swift files where both sides added a `case` to the same `enum`/`switch` — union both cases manually.
   - Tests under `cmuxTests/` and CI configs (`.github/workflows/*.yml`, `scripts/*.sh`) — usually keep ours.

2. **For Swift product files** (`Sources/`, `Packages/`): hand-resolve. The dominant pattern is union: both sides added a sibling case (chatmux's `.claudeChat` + upstream's `.agentSession`) — keep both. After each file: `git add <file>`. Do **not** run the helper on these; it nukes upstream's hunks.

3. **For `Resources/Localizable.xcstrings`** (JSON): use a programmatic key-level union, preferring ours on collisions:
   ```bash
   git show :2:Resources/Localizable.xcstrings > /tmp/loc-ours.json
   git show :3:Resources/Localizable.xcstrings > /tmp/loc-theirs.json
   python3 -c "
   import json
   from collections import OrderedDict
   ours = json.load(open('/tmp/loc-ours.json'), object_pairs_hook=OrderedDict)
   theirs = json.load(open('/tmp/loc-theirs.json'), object_pairs_hook=OrderedDict)
   merged = OrderedDict()
   merged['sourceLanguage'] = ours.get('sourceLanguage', 'en')
   merged['strings'] = OrderedDict()
   for k in sorted(set(ours['strings']) | set(theirs['strings'])):
       merged['strings'][k] = ours['strings'].get(k, theirs['strings'][k])
   merged['version'] = ours.get('version', '1.0')
   json.dump(merged, open('Resources/Localizable.xcstrings', 'w'), indent=2, ensure_ascii=False)
   open('Resources/Localizable.xcstrings', 'a').write('\n')
   "
   git add Resources/Localizable.xcstrings
   ```

4. **For `cmux.xcodeproj/project.pbxproj`**: union merge then dedup, NOT `--ours`. The helper's `--ours` strategy drops fork-only entries and definitions added on the upstream side both:
   ```bash
   git show :2:cmux.xcodeproj/project.pbxproj > /tmp/pbxproj-ours.txt
   git show :3:cmux.xcodeproj/project.pbxproj > /tmp/pbxproj-theirs.txt
   git show :1:cmux.xcodeproj/project.pbxproj > /tmp/pbxproj-base.txt
   git merge-file --union -p /tmp/pbxproj-ours.txt /tmp/pbxproj-base.txt /tmp/pbxproj-theirs.txt > cmux.xcodeproj/project.pbxproj
   # Then dedup + verify with the Python in scripts/sync-upstream-resolve.py (its
   # dedup pass alone is safe; the conflict-marker pass is what destroys union work).
   ```
   Then run `python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj && scripts/check-pbxproj.sh`. Fix any broken IDs by hand (typical: missing `PBXBuildFile` definitions for the cmux-cli target, missing `XCLocalSwiftPackageReference` blocks, stray references to files that no longer exist in the working tree).

   `git add cmux.xcodeproj/project.pbxproj`.

### 6. Make sure the submodule pointers are correct

```bash
git submodule update vendor/bonsplit
git ls-tree HEAD vendor/bonsplit
```

The pointer reported by `ls-tree HEAD` should match `upstream_bonsplit` from step 3. If it doesn't, `cd vendor/bonsplit && git checkout $upstream_bonsplit && cd - && git add vendor/bonsplit`.

Same check for `ghostty`: upstream often bumps the ghostty submodule and that brings new C functions the Swift side now calls (`ghostty_surface_set_pty_tee_cb`, `ghostty_surface_render_grid_json`, etc.). If you skip the ghostty bump, the build fails with "cannot find …  in scope":

```bash
upstream_ghostty=$(git ls-tree origin/main ghostty | awk '{print $3}')
cd ghostty && git checkout $upstream_ghostty && cd -
git add ghostty
```

### 7. Finish the merge commit

```bash
git commit --no-edit
```

Don't amend or rewrite the message. The default `Merge remote-tracking branch 'origin/main' into main-merge-…` is what git history needs to recognise the merge.

Verify:

```bash
git merge-base --is-ancestor origin/main HEAD && echo "OK: upstream is now ancestor"
git log --oneline --cherry-pick --right-only HEAD...origin/main | wc -l  # expect 0
```

### 8. Push the temp branch and ask the user to build

```bash
git push fork "main-merge-$suffix"
```

Surface the branch name to the user and ask them to run their build. The known good command is:

```bash
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/reload.sh --tag <tag> --launch
```

**Wait for explicit confirmation that the build succeeded before continuing.** If the build fails, debug from the temp branch (the user's `main` is still untouched).

Expect at least one round of switch-exhaustivity build errors after the merge — every `switch panel.panelType` or `switch RightSidebarMode` that handles `.claudeChat`/`.gitlab`/etc. needs the new upstream case (`.agentSession`) and vice versa. Fix in place, commit on the temp branch, rebuild.

### 9. Fast-forward `main` and clean up

Once the user confirms the build works:

```bash
git checkout main
git merge --ff-only "main-merge-$suffix"
git push fork main
git branch -d "main-merge-$suffix"
git push fork --delete "main-merge-$suffix"
```

### 10. Report

Summarise:
- `upstream-main` now at: `<SHA> <subject>`
- `main` now at: `<merge-SHA>`
- Bonsplit pointer: `<sha>`
- Ghostty pointer: `<sha>`
- How many genuine new upstream commits landed (= `git rev-list <previous main>..main --count`).

## Notes

- This fork is a derivative project, not a contributor fork. `main` is the working branch; `upstream-main` is a tracking mirror. If someday a feature *does* go upstream, branch the contribution off `upstream-main`, cherry-pick the relevant commits clean, and open the PR from there — the layout below was chosen so that path stays open.
- After the merge, the personal MCP/bashes files (`Sources/Panels/McpManagerPopover.swift`, `Sources/Panels/BackgroundShellsPopover.swift`, `Sources/ClaudeChat/McpHealthProber.swift`, `Sources/ClaudeChat/McpServerCatalog.swift`) and the focus-regain fix (`Sources/CmuxLifecycleEventPublishing.swift`) should still be there. If they're missing, something went wrong with the merge — restore from `main` (pre-merge) and investigate.
- Don't run this command in a worktree where the submodules aren't fully checked out. The submodule pointer step depends on `git ls-tree` returning real refs.
- `scripts/sync-upstream-resolve.py` is kept for historical reference but its conflict-marker pass should not be used: it discards upstream additions in conflicted Swift files and fork-only entries in the pbxproj. Its `_verify_pbxproj` integrity check is still useful standalone.
