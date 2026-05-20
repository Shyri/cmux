#!/usr/bin/env python3
"""Auto-resolve helper used by the `/sync-upstream` slash command.

Two responsibilities, both idempotent:

1. **Resolve conflict markers in `cmux.xcodeproj/project.pbxproj`** by
   keeping the upstream-added lines (the file is mostly a list of stable
   IDs that don't merge well, but the upstream side is the additive
   one). Then dedupe `PBXBuildFile` / `PBXFileReference` lines by exact
   text and dedupe `XCSwiftPackageProductDependency`,
   `XCLocalSwiftPackageReference`, `XCRemoteSwiftPackageReference`
   blocks by their leading 24-hex ID. This is the same logic we've
   used by hand over the last few merges and it matches what Xcode
   tolerates in practice.

2. **Resolve other conflicted files by keeping our side** (`--ours`).
   The assumption: `chatmux` already integrates whatever the upstream
   patch was trying to add, just with a different patch-id (because we
   amended commits during prior cherry-pick rounds). Anything genuinely
   new from upstream that we haven't applied yet is what the calling
   `git merge` brings as new commits in the right-only diff, and those
   land via the merge commit itself, not via individual hunks.

Usage:

    python3 scripts/sync-upstream-resolve.py

Exits with 0 if every conflict was resolved automatically, 1 if any
conflict required manual attention (the calling script should stop and
ask the user).
"""
from __future__ import annotations

import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

PBXPROJ = "cmux.xcodeproj/project.pbxproj"


def _git_unmerged() -> list[str]:
    out = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=U"],
        capture_output=True, text=True, check=True,
    ).stdout
    return [line for line in out.splitlines() if line]


def _resolve_pbxproj(path: str) -> None:
    """Drop the `<<<<<<< HEAD ... ======= ... >>>>>>>` markers keeping the
    right-hand-side (upstream additions), then dedupe single-line entries
    and Swift-package blocks. The script mutates `path` in place."""
    text = Path(path).read_text()

    marker = re.compile(
        r"<<<<<<< HEAD\n(.*?)=======\n(.*?)>>>>>>> [^\n]+\n",
        re.DOTALL,
    )
    text, _ = marker.subn(lambda m: m.group(2), text)

    # Dedupe identical single-line `... = {isa = PBXBuildFile/PBXFileReference; ...};`
    lines = text.splitlines(keepends=True)
    seen: set[str] = set()
    out: list[str] = []
    for line in lines:
        stripped = line.strip()
        if stripped.endswith("};") and (
            "isa = PBXBuildFile" in stripped or "isa = PBXFileReference" in stripped
        ):
            if stripped in seen:
                continue
            seen.add(stripped)
        out.append(line)
    text = "".join(out)

    # Dedupe entire blocks (XCSwiftPackage*, XCLocalSwiftPackageReference,
    # XCRemoteSwiftPackageReference) by their leading ID.
    for isa in (
        "XCSwiftPackageProductDependency",
        "XCLocalSwiftPackageReference",
        "XCRemoteSwiftPackageReference",
    ):
        block_pat = re.compile(
            r"\t\t([0-9A-Fa-f]+)\s+/\*[^*]+\*/\s*=\s*\{\s*\n"
            rf"\t\t\tisa\s*=\s*{isa};[^}}]*?\t\t\}};\s*\n",
            re.DOTALL,
        )
        seen_ids: set[str] = set()

        def keep_first(match: re.Match[str]) -> str:
            ident = match.group(1)
            if ident in seen_ids:
                return ""
            seen_ids.add(ident)
            return match.group(0)

        text = block_pat.sub(keep_first, text)

    Path(path).write_text(text)


def _verify_pbxproj(path: str) -> list[str]:
    """Return a list of problems found in `path`. Empty list means the
    file is structurally consistent enough for Xcode to load it."""
    text = Path(path).read_text()
    problems: list[str] = []

    markers = sum(
        1 for line in text.splitlines()
        if line.startswith(("<<<<<<<", ">>>>>>>"))
    )
    if markers:
        problems.append(f"{markers} unresolved conflict markers")

    defs = re.findall(
        r"^\s*([0-9A-Fa-f]+)\s+/\*[^*]+\*/\s*=\s*\{",
        text, re.MULTILINE,
    )
    dup_ids = [ident for ident, count in Counter(defs).items() if count > 1]
    if dup_ids:
        problems.append(
            f"{len(dup_ids)} duplicate ID definitions (e.g. {dup_ids[:3]})"
        )

    defined = set(defs)
    referenced: set[str] = set()
    referenced.update(re.findall(
        r"^\s*([0-9A-Fa-f]+)\s+/\*[^*]+\*/,",
        text, re.MULTILINE,
    ))
    referenced.update(re.findall(
        r"(?:fileRef|productRef|package)\s*=\s*([0-9A-Fa-f]+)\s+/",
        text,
    ))
    broken = referenced - defined
    if broken:
        problems.append(
            f"{len(broken)} references to undefined IDs (e.g. {sorted(broken)[:3]})"
        )

    return problems


def main() -> int:
    conflicts = _git_unmerged()
    if not conflicts:
        print("no conflicts to resolve")
        return 0

    for path in conflicts:
        if path == PBXPROJ:
            _resolve_pbxproj(path)
            subprocess.run(["git", "add", "--", path], check=True)
            continue

        # Accept our side. If the file was deleted on our side, mark the
        # deletion as the resolution.
        result = subprocess.run(
            ["git", "checkout", "--ours", "--", path],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            subprocess.run(["git", "rm", "--", path], check=True, capture_output=True)
        else:
            subprocess.run(["git", "add", "--", path], check=True)

    remaining = _git_unmerged()
    if remaining:
        print("could not auto-resolve:", file=sys.stderr)
        for r in remaining:
            print(f"  {r}", file=sys.stderr)
        return 1

    problems = _verify_pbxproj(PBXPROJ)
    if problems:
        print("pbxproj integrity warnings (review before committing):", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        return 1

    print("all conflicts resolved automatically")
    return 0


if __name__ == "__main__":
    sys.exit(main())
