import Foundation

// MARK: - Models

enum GitDiffChangeType: String, Sendable {
    case added = "A"
    case modified = "M"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typeChanged = "T"
    case unknown = "?"

    static func parse(_ raw: String) -> GitDiffChangeType {
        switch raw.first {
        case "A": return .added
        case "M": return .modified
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        default: return .unknown
        }
    }

    var symbol: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .unknown: return "?"
        }
    }
}

struct GitDiffFile: Identifiable, Equatable, Sendable, Hashable {
    var id: String { path }
    let path: String
    let oldPath: String?
    let changeType: GitDiffChangeType
    let additions: Int
    let deletions: Int
    let isBinary: Bool
    /// Set when this file would conflict if `compare` were merged into `base`
    /// (for ranged diffs) or is currently in an unmerged state in the working
    /// tree. Drives the conflict indicator in the file list.
    var hasConflict: Bool = false
}

/// Describes what to diff. `compare == nil` means the working tree.
struct GitDiffSpec: Equatable, Sendable {
    let base: String
    let compare: String?
    let directory: String
    let title: String
    /// When non-empty, limits the diff to these pathspecs (passed after `--`).
    /// Used by the working-copy "Changes" view to open a single clicked file
    /// instead of the whole tree.
    var pathspec: [String]? = nil
    /// Set when the diff was opened from a GitLab merge request. Enables the
    /// "Approve" button in the window toolbar.
    var mergeRequestIID: Int? = nil
    var mergeRequestURL: String? = nil
}

// MARK: - Errors

enum GitDiffError: Error, Sendable {
    case gitNotFound
    case notAGitRepo
    case processError(String)
    /// One or both sides of the diff couldn't be resolved to a local or
    /// remote-tracking ref. The payload lists the original branch names so
    /// the UI can offer a fetch-and-retry action.
    case missingRefs(branches: [String], remote: String)
}

// MARK: - Ref resolution

/// For each branch, prefer the remote-tracking ref so the diff matches what
/// GitLab sees even when the user's local branch is stale or absent. Falls
/// back to the local name; returns nil if neither exists.
private func resolveRef(
    _ branch: String,
    directory: String,
    remote: String
) async -> String? {
    for candidate in ["\(remote)/\(branch)", branch] {
        do {
            _ = try await runGit(
                args: ["rev-parse", "--verify", "--quiet", "\(candidate)^{commit}"],
                directory: directory
            )
            return candidate
        } catch {
            continue
        }
    }
    return nil
}

/// Default remote used when resolving or fetching MR refs.
let gitDiffDefaultRemote = "origin"

private func gitDiffDebugLog(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    let path = "/tmp/cmux-gitdiff-debug.log"
    if let data = line.data(using: .utf8) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Resolve the `spec`'s refs, throwing `missingRefs` if any side can't be
/// resolved. Returns the actual ref names usable by git commands.
///
/// For MR specs, the *base* side stays live (`origin/<target>`) and only the
/// *compare* side is anchored to GitLab's `diff_refs.head_sha`. This mirrors
/// what the panel web view does: commits already merged into the target (via
/// other MRs landing in the meantime) are excluded from the diff because the
/// merge-base — recomputed by `git diff base...compare` (three dots) — moves
/// forward with target. Anchoring only the compare side also keeps the diff
/// stable against force-pushes or deletions on the source branch.
///
/// Also forces a one-shot `git fetch` of the target branch so the local
/// `origin/<target>` reflects what GitLab sees. Without this, a local repo
/// that hasn't pulled recently would compute a stale merge-base and show
/// chunks that are no longer in the panel because they've since landed in
/// target via other MRs.
private func resolveSpecRefs(_ spec: GitDiffSpec) async throws -> (base: String, compare: String?) {
    let remote = gitDiffDefaultRemote

    if spec.mergeRequestIID != nil {
        await TargetBranchFetchCache.shared.ensureFetched(
            branch: spec.base,
            remote: remote,
            directory: spec.directory
        )
    }

    let resolvedBase = await resolveRef(spec.base, directory: spec.directory, remote: remote)

    var resolvedCompare: String? = nil
    if let iid = spec.mergeRequestIID {
        let refs = try await fetchMRDiffRefsAsGitDiffError(iid: iid, directory: spec.directory)
        try await ensureGitCommitsPresent(
            [refs.headSHA],
            remote: remote,
            directory: spec.directory,
            mrIID: iid
        )
        resolvedCompare = refs.headSHA
    } else if let compare = spec.compare {
        resolvedCompare = await resolveRef(compare, directory: spec.directory, remote: remote)
    }

    var missing: [String] = []
    if resolvedBase == nil { missing.append(spec.base) }
    if spec.mergeRequestIID == nil, let compare = spec.compare, resolvedCompare == nil {
        missing.append(compare)
    }
    if !missing.isEmpty {
        gitDiffDebugLog("missing refs base=\(spec.base) compare=\(spec.compare ?? "-") missing=\(missing) remote=\(remote) dir=\(spec.directory)")
        throw GitDiffError.missingRefs(branches: missing, remote: remote)
    }

    return (resolvedBase!, resolvedCompare)
}

/// Coalesces target-branch `git fetch` calls per (directory, branch). A diff
/// window opens once but calls `resolveSpecRefs` N times (one per file); we
/// must not refetch every time. The cache is invalidated by `reload()` on the
/// view model when the user explicitly refreshes.
actor TargetBranchFetchCache {
    static let shared = TargetBranchFetchCache()
    private var fetched: Set<String> = []

    private func key(branch: String, directory: String) -> String {
        "\(directory)|\(branch)"
    }

    func ensureFetched(branch: String, remote: String, directory: String) async {
        let k = key(branch: branch, directory: directory)
        guard !fetched.contains(k) else { return }
        // Mark optimistically: even if the fetch fails (offline, transient
        // network error), we don't want to spam retries on every file click.
        // The user's manual reload() invalidates this cache.
        fetched.insert(k)
        do {
            try await fetchGitBranches([branch], remote: remote, directory: directory)
            gitDiffDebugLog("target-fetch branch=\(branch) remote=\(remote) dir=\(directory)")
        } catch {
            gitDiffDebugLog("target-fetch failed branch=\(branch) error=\(error)")
        }
    }

    func invalidate(branch: String, directory: String) {
        fetched.remove(key(branch: branch, directory: directory))
    }
}

/// Resolve the `spec`'s refs to ones that exist locally, preferring the
/// remote-tracking branch. Throws `missingRefs` if any side can't be resolved
/// so the UI can surface a fetch-and-retry action.
///
/// For MR specs uses GitLab's panel semantics: `git merge-tree --write-tree`
/// simulates merging the MR into the current target, then `git diff
/// <target_HEAD> <merged_tree>`. That filters out cherry-picked duplicates
/// (commits with identical patch-id that landed in target via another MR)
/// because the merge recognizes them as already applied. If `merge-tree`
/// fails for any reason, falls back to two-dot (`<target> <head>`) which is
/// what GitLab's "Compare HEAD and latest version" view degrades to.
///
/// Non-MR ranges keep three-dot (`base...compare`) merge-base semantics so
/// working-tree and branch-vs-branch diffs aren't polluted by unrelated
/// target commits.
private func resolvedRangeArgs(for spec: GitDiffSpec) async throws -> [String] {
    let resolved = try await resolveSpecRefs(spec)
    if spec.mergeRequestIID != nil, let compare = resolved.compare {
        do {
            let mergedTreeOID = try await MRMergedTreeStore.shared.mergedTreeOID(
                target: resolved.base,
                head: compare,
                directory: spec.directory
            )
            gitDiffDebugLog("range mr base=\(resolved.base) merged-tree=\(mergedTreeOID) (panel-semantics) dir=\(spec.directory)")
            return [resolved.base, mergedTreeOID]
        } catch {
            gitDiffDebugLog("merge-tree failed, falling back to two-dot: \(error)")
            return [resolved.base, compare]
        }
    }
    if let compare = resolved.compare {
        let range = "\(resolved.base)...\(compare)"
        gitDiffDebugLog("range base=\(spec.base) -> \(resolved.base) compare=\(spec.compare ?? "-") -> \(compare) args=\(range) dir=\(spec.directory)")
        return [range]
    }
    gitDiffDebugLog("range single base=\(spec.base) -> \(resolved.base) dir=\(spec.directory)")
    return [resolved.base]
}

/// Runs `git merge-tree --write-tree <target> <head>` and returns the
/// resulting tree OID. Exit status 0 = clean merge, 1 = conflicts present
/// (the tree is still written, with `<<<<<<<` markers inline on the
/// conflicting files). Anything else is an error.
///
/// Lives here (alongside the other git helpers) so the actor in
/// `MRMergedTreeStore.swift` can call it without exposing `runGitAllowingNonZero`
/// across module boundaries.
func computeMergeTreeOID(target: String, head: String, directory: String) async throws -> String {
    let result = try await runGitAllowingNonZero(
        args: ["merge-tree", "--write-tree", "--no-messages", target, head],
        directory: directory
    )
    guard result.status == 0 || result.status == 1 else {
        let err = String(data: result.stderr, encoding: .utf8) ?? ""
        throw GitDiffError.processError(
            "merge-tree failed (exit \(result.status)): \(err.prefix(300))"
        )
    }
    guard let raw = String(data: result.stdout, encoding: .utf8),
          let firstNewline = raw.firstIndex(of: "\n") else {
        throw GitDiffError.processError("merge-tree produced no output")
    }
    let oid = String(raw[..<firstNewline]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !oid.isEmpty else {
        throw GitDiffError.processError("merge-tree produced empty tree OID")
    }
    return oid
}

/// Bridge `MRDiffRefsStore` errors into `GitDiffError` so the diff window's
/// error rendering shows a consistent message regardless of whether the
/// failure came from git or glab. The underlying message is preserved.
private func fetchMRDiffRefsAsGitDiffError(iid: Int, directory: String) async throws -> MRDiffRefs {
    do {
        return try await MRDiffRefsStore.shared.refs(iid: iid, directory: directory)
    } catch let e as MRDiscussionsFetchError {
        switch e {
        case .glabNotFound:
            throw GitDiffError.processError(
                "glab not found — install glab to view this MR's diff with GitLab parity"
            )
        case .processError(let msg):
            throw GitDiffError.processError(
                msg.isEmpty ? "Failed to fetch MR diff_refs from GitLab" : msg
            )
        case .parseError:
            throw GitDiffError.processError("Failed to parse GitLab MR response")
        }
    } catch {
        throw GitDiffError.processError(error.localizedDescription)
    }
}

// MARK: - Commit presence

/// Ensures each SHA exists locally so subsequent `git diff`/`merge-tree` calls
/// can resolve them. Mirrors `fetchGitBranches`'s role but for SHA-pinned MR
/// flows: SHAs may not match any local ref name, especially after force-pushes
/// or when the source branch has been deleted from the remote.
///
/// Strategy: verify with `rev-parse`, then attempt a single `git fetch` for
/// missing SHAs (works on GitLab ≥ 14 with `uploadpack.allowReachableSHA1InWant`).
/// On failure, fall back to fetching `refs/merge-requests/<iid>/head` — GitLab's
/// MR ref namespace, which keeps the MR's head commit reachable even when the
/// source branch is gone.
func ensureGitCommitsPresent(
    _ shas: [String],
    remote: String,
    directory: String,
    mrIID: Int?
) async throws {
    var missing = await commitsMissingLocally(shas, directory: directory)
    if missing.isEmpty { return }

    // Try fetching the missing SHAs directly. Requires the server to allow
    // fetching by SHA (GitLab does by default; some self-hosted setups don't).
    _ = try? await runGitAllowingNonZero(
        args: ["fetch", "--no-tags", remote] + missing,
        directory: directory
    )
    missing = await commitsMissingLocally(missing, directory: directory)
    if missing.isEmpty { return }

    // Fallback: GitLab exposes the MR head at refs/merge-requests/<iid>/head.
    // Fetching that ref ensures at least the head SHA is present; the base SHA
    // is typically reachable from the target branch so it gets brought in by
    // the same fetch when traversing history.
    if let iid = mrIID {
        let refspec = "+refs/merge-requests/\(iid)/head:refs/remotes/\(remote)/merge-requests/\(iid)/head"
        _ = try? await runGitAllowingNonZero(
            args: ["fetch", "--no-tags", remote, refspec],
            directory: directory
        )
        missing = await commitsMissingLocally(missing, directory: directory)
        if missing.isEmpty { return }
    }

    gitDiffDebugLog("missing commits after fetch attempts: \(missing) remote=\(remote) dir=\(directory)")
    throw GitDiffError.missingRefs(branches: missing, remote: remote)
}

private func commitsMissingLocally(_ shas: [String], directory: String) async -> [String] {
    var missing: [String] = []
    for sha in shas {
        let result = try? await runGitAllowingNonZero(
            args: ["rev-parse", "--verify", "--quiet", "\(sha)^{commit}"],
            directory: directory
        )
        if (result?.status ?? 1) != 0 {
            missing.append(sha)
        }
    }
    return missing
}

/// Returns true when the given string looks like a git SHA (7-40 hex chars),
/// used by the diff window to route retries through `ensureGitCommitsPresent`
/// instead of `fetchGitBranches`.
func looksLikeGitSHA(_ s: String) -> Bool {
    guard s.count >= 7, s.count <= 40 else { return false }
    return s.allSatisfy { c in
        ("0"..."9").contains(c) || ("a"..."f").contains(c) || ("A"..."F").contains(c)
    }
}

func fetchGitBranches(_ branches: [String], remote: String, directory: String) async throws {
    guard !branches.isEmpty else { return }
    // Use explicit refspecs so `refs/remotes/<remote>/<branch>` is always
    // updated, regardless of the user's configured `remote.<remote>.fetch`.
    let refspecs = branches.map { "+refs/heads/\($0):refs/remotes/\(remote)/\($0)" }
    _ = try await runGit(
        args: ["fetch", "--no-tags", remote] + refspecs,
        directory: directory
    )
}

/// Heuristically detects git errors that signal an unresolvable revision or
/// range, so callers can surface a fetch-and-retry affordance instead of the
/// raw stderr message.
private func looksLikeMissingRevision(_ message: String) -> Bool {
    let lower = message.lowercased()
    return lower.contains("ambiguous argument")
        || lower.contains("unknown revision")
        || lower.contains("bad revision")
        || lower.contains("no merge base")
}

private func rethrowAsMissingRefs(_ error: Error, spec: GitDiffSpec) -> Error {
    guard case let GitDiffError.processError(msg) = error,
          looksLikeMissingRevision(msg) else { return error }
    var branches: [String] = [spec.base]
    if let compare = spec.compare { branches.append(compare) }
    return GitDiffError.missingRefs(branches: branches, remote: gitDiffDefaultRemote)
}

// MARK: - Fetchers

func fetchChangedFiles(spec: GitDiffSpec) async throws -> [GitDiffFile] {
    let rangeArgs = try await resolvedRangeArgs(for: spec)
    let pathspecArgs = spec.pathspec ?? []
    let numstat: String
    let nameStatus: String
    do {
        numstat = try await runGit(
            args: ["diff", "--numstat", "-z"] + rangeArgs + ["--"] + pathspecArgs,
            directory: spec.directory
        )
        nameStatus = try await runGit(
            args: ["diff", "--name-status", "-z"] + rangeArgs + ["--"] + pathspecArgs,
            directory: spec.directory
        )
    } catch {
        throw rethrowAsMissingRefs(error, spec: spec)
    }

    let stats = parseNumstat(numstat)
    let statuses = parseNameStatus(nameStatus)
    gitDiffDebugLog("numstat bytes=\(numstat.utf8.count) nameStatus bytes=\(nameStatus.utf8.count) statuses=\(statuses.count) numstatRaw=\(numstat.debugDescription.prefix(300)) nameStatusRaw=\(nameStatus.debugDescription.prefix(300))")

    var result: [GitDiffFile] = []
    var seen = Set<String>()
    for s in statuses {
        let key = s.path
        guard seen.insert(key).inserted else { continue }
        let stat = stats[key]
        result.append(GitDiffFile(
            path: s.path,
            oldPath: s.oldPath,
            changeType: s.changeType,
            additions: stat?.additions ?? 0,
            deletions: stat?.deletions ?? 0,
            isBinary: stat?.isBinary ?? false
        ))
    }
    return result
}

/// One conflict region inside a merged file. Line numbers are 1-based and
/// refer to the merged result (the file produced by `git merge-tree`), so
/// callers can tell the user "conflict at L42-L60".
struct GitDiffConflictRegion: Equatable, Sendable, Hashable {
    let startLine: Int
    let endLine: Int
}

/// Conflict info for a single file: the line ranges (in the merged result)
/// where conflict markers appear. Empty if the file has no conflict.
struct GitDiffFileConflict: Equatable, Sendable, Hashable {
    let path: String
    let regions: [GitDiffConflictRegion]
}

/// Returns the set of file paths that would conflict if `spec.compare` were
/// merged into `spec.base`. For working-tree diffs (`compare == nil`), returns
/// paths currently in an unmerged state per `git ls-files -u`.
///
/// Failures (missing `merge-tree` support, unrelated histories, etc.) are
/// swallowed and logged — conflict marking is a hint, not load-bearing.
func fetchConflictingPaths(spec: GitDiffSpec) async -> Set<String> {
    do {
        if spec.compare != nil {
            let resolved = try await resolveSpecRefs(spec)
            guard let compare = resolved.compare else { return [] }
            // git 2.38+: `merge-tree --write-tree` performs a 3-way merge of
            // the two commits and exits non-zero with the conflicted paths
            // listed when conflicts exist. `--name-only --no-messages -z`
            // produces NUL-separated output: `<tree-oid>\0<path>\0...\0`.
            let result = try await runGitAllowingNonZero(
                args: [
                    "merge-tree",
                    "--write-tree",
                    "--name-only",
                    "--no-messages",
                    "-z",
                    resolved.base,
                    compare,
                ],
                directory: spec.directory
            )
            // Exit code 0 = clean merge, 1 = conflicts, anything else = error.
            if result.status == 0 {
                return []
            }
            if result.status != 1 {
                let errStr = String(data: result.stderr, encoding: .utf8) ?? ""
                gitDiffDebugLog("merge-tree exit=\(result.status) stderr=\(errStr.prefix(300))")
                return []
            }
            let raw = String(data: result.stdout, encoding: .utf8) ?? ""
            var tokens = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
            // Drop the resulting tree OID (first token).
            if !tokens.isEmpty { tokens.removeFirst() }
            return Set(tokens)
        } else {
            // Working tree: `git ls-files -u -z` lists unmerged entries with
            // stage > 0. Multiple stage entries per path; dedup via Set.
            let raw = try await runGit(
                args: ["ls-files", "-u", "-z"],
                directory: spec.directory
            )
            var paths = Set<String>()
            for record in raw.split(separator: "\0", omittingEmptySubsequences: true) {
                // Format: <mode> <sha> <stage>\t<path>
                if let tab = record.firstIndex(of: "\t") {
                    paths.insert(String(record[record.index(after: tab)...]))
                }
            }
            return paths
        }
    } catch {
        gitDiffDebugLog("fetchConflictingPaths failed: \(error)")
        return []
    }
}

/// For a file flagged as conflicting, runs `git merge-tree --write-tree` to
/// produce the merged tree, reads the merged blob via `git show <tree>:<path>`,
/// and returns the line ranges where conflict markers appear. Returns `nil` if
/// no conflict could be computed (e.g., spec has no compare side, merge-tree
/// failed, or the file isn't actually conflicting).
func fetchConflictRegions(spec: GitDiffSpec, path: String) async -> GitDiffFileConflict? {
    guard spec.compare != nil else { return nil }
    do {
        let resolved = try await resolveSpecRefs(spec)
        guard let compare = resolved.compare else { return nil }
        // Without `--name-only` and with `--no-messages`, merge-tree prints:
        //   <tree-oid>\n<conflict-info-section>
        // where each conflict-info line is `<mode> <oid> <stage>\t<path>`.
        // Exit 1 = conflicts present, 0 = clean.
        let result = try await runGitAllowingNonZero(
            args: [
                "merge-tree",
                "--write-tree",
                "--no-messages",
                resolved.base,
                compare,
            ],
            directory: spec.directory
        )
        guard result.status == 1 else { return nil }
        guard let raw = String(data: result.stdout, encoding: .utf8),
              let firstNewline = raw.firstIndex(of: "\n") else { return nil }
        let treeOID = String(raw[..<firstNewline])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !treeOID.isEmpty else { return nil }

        // Read the merged blob. May fail for binary files or files that
        // resolved cleanly even though other files conflicted.
        let blob: String
        do {
            blob = try await runGit(
                args: ["show", "\(treeOID):\(path)"],
                directory: spec.directory
            )
        } catch {
            return nil
        }
        let regions = parseConflictRegions(in: blob)
        return regions.isEmpty ? nil : GitDiffFileConflict(path: path, regions: regions)
    } catch {
        gitDiffDebugLog("fetchConflictRegions failed for \(path): \(error)")
        return nil
    }
}

private func parseConflictRegions(in content: String) -> [GitDiffConflictRegion] {
    var regions: [GitDiffConflictRegion] = []
    var startLine: Int? = nil
    var lineNo = 0
    content.enumerateLines { line, _ in
        lineNo += 1
        if line.hasPrefix("<<<<<<<") {
            startLine = lineNo
        } else if line.hasPrefix(">>>>>>>"), let s = startLine {
            regions.append(GitDiffConflictRegion(startLine: s, endLine: lineNo))
            startLine = nil
        }
    }
    return regions
}

func fetchUnifiedDiff(spec: GitDiffSpec, file: String) async throws -> String {
    // `-U999999` asks git to include every unchanged line as context, so the
    // renderer shows the whole file with additions/deletions interleaved —
    // matching VS Code's behaviour instead of only the ±3 lines around hunks.
    let rangeArgs = try await resolvedRangeArgs(for: spec)
    let args: [String] = [
        "-c", "color.ui=never",
        "diff",
        "--no-color",
        "--no-ext-diff",
        "-U999999",
    ] + rangeArgs + ["--", file]
    do {
        return try await runGit(args: args, directory: spec.directory, stringOutput: true)
    } catch {
        throw rethrowAsMissingRefs(error, spec: spec)
    }
}

/// Same as `fetchUnifiedDiff`, but for conflicting files diffs `base` against
/// the merged tree produced by `git merge-tree --write-tree`. The merged blob
/// contains `<<<<<<<`/`=======`/`>>>>>>>` markers inline, so the diff renderer
/// (which detects those via `conflictMarkerKind`) shows the conflict regions
/// directly on the affected lines instead of needing a separate banner.
///
/// Falls back to the regular diff if the merged tree can't be produced (no
/// compare side, missing `merge-tree --write-tree` support, etc.).
///
/// For MR specs, base = live `origin/<target>` and compare = GitLab's
/// `head_sha`. That keeps conflict prediction honest (against the current
/// target HEAD) and stable against source-branch force-pushes.
func fetchUnifiedDiffWithConflictMarkers(spec: GitDiffSpec, file: String) async throws -> String {
    guard spec.compare != nil else {
        return try await fetchUnifiedDiff(spec: spec, file: file)
    }
    let resolved: (base: String, compare: String?)
    do {
        resolved = try await resolveSpecRefs(spec)
    } catch {
        return try await fetchUnifiedDiff(spec: spec, file: file)
    }
    guard let compare = resolved.compare else {
        return try await fetchUnifiedDiff(spec: spec, file: file)
    }
    do {
        let mergeResult = try await runGitAllowingNonZero(
            args: [
                "merge-tree",
                "--write-tree",
                "--no-messages",
                resolved.base,
                compare,
            ],
            directory: spec.directory
        )
        guard mergeResult.status == 1,
              let raw = String(data: mergeResult.stdout, encoding: .utf8),
              let firstNewline = raw.firstIndex(of: "\n") else {
            return try await fetchUnifiedDiff(spec: spec, file: file)
        }
        let treeOID = String(raw[..<firstNewline])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !treeOID.isEmpty else {
            return try await fetchUnifiedDiff(spec: spec, file: file)
        }
        let args: [String] = [
            "-c", "color.ui=never",
            "diff",
            "--no-color",
            "--no-ext-diff",
            "-U999999",
            resolved.base,
            treeOID,
            "--", file,
        ]
        return try await runGit(args: args, directory: spec.directory, stringOutput: true)
    } catch {
        return try await fetchUnifiedDiff(spec: spec, file: file)
    }
}

// MARK: - git process runner

private func runGit(
    args: [String],
    directory: String,
    stringOutput: Bool = false
) async throws -> String {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let out = try runGitSync(args: args, directory: directory)
                cont.resume(returning: out)
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

/// Runs git but does not throw on non-zero exit. Returns stdout/stderr bytes
/// alongside the termination status so callers (e.g., `merge-tree`, which uses
/// exit 1 to signal conflicts) can interpret the result.
private struct GitRunResult: Sendable {
    let stdout: Data
    let stderr: Data
    let status: Int32
}

private func runGitAllowingNonZero(
    args: [String],
    directory: String
) async throws -> GitRunResult {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GitRunResult, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try runGitAllowingNonZeroSync(args: args, directory: directory)
                cont.resume(returning: result)
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

private func runGitAllowingNonZeroSync(args: [String], directory: String) throws -> GitRunResult {
    guard let gitPath = findGitExecutable() else {
        throw GitDiffError.gitNotFound
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: gitPath)
    var env = ProcessInfo.processInfo.environment
    env["GIT_PAGER"] = "cat"
    env["PAGER"] = "cat"
    env["LC_ALL"] = "C"
    process.environment = env
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: directory)

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    let (outData, errData) = drainPipesInParallel(stdout: stdout, stderr: stderr)
    process.waitUntilExit()
    return GitRunResult(stdout: outData, stderr: errData, status: process.terminationStatus)
}

private func runGitSync(args: [String], directory: String) throws -> String {
    guard let gitPath = findGitExecutable() else {
        throw GitDiffError.gitNotFound
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: gitPath)
    // Unset git pager and locale interference
    var env = ProcessInfo.processInfo.environment
    env["GIT_PAGER"] = "cat"
    env["PAGER"] = "cat"
    env["LC_ALL"] = "C"
    process.environment = env
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: directory)

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    let (outData, errData) = drainPipesInParallel(stdout: stdout, stderr: stderr)
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        if errStr.contains("not a git repository") {
            throw GitDiffError.notAGitRepo
        }
        throw GitDiffError.processError(errStr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return String(data: outData, encoding: .utf8) ?? ""
}

private func findGitExecutable() -> String? {
    let candidates = [
        "/usr/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
    ]
    if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
        for dir in pathEnv.split(separator: ":") {
            let full = "\(dir)/git"
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
    }
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    return nil
}

// MARK: - parsing

private struct NumstatEntry {
    let additions: Int
    let deletions: Int
    let isBinary: Bool
}

private func parseNumstat(_ raw: String) -> [String: NumstatEntry] {
    // Format with -z: records separated by NUL.
    // Each record: "<adds>\t<dels>\t<path>\0"
    // Rename record: "<adds>\t<dels>\t\0<oldPath>\0<newPath>\0"
    var map: [String: NumstatEntry] = [:]
    let scanner = NulScanner(raw)
    while let head = scanner.next() {
        if head.isEmpty { continue }
        let parts = head.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { continue }
        let a = String(parts[0])
        let d = String(parts[1])
        let isBin = a == "-" || d == "-"
        let adds = Int(a) ?? 0
        let dels = Int(d) ?? 0

        var path: String
        if parts.count == 3 && !parts[2].isEmpty {
            path = String(parts[2])
        } else {
            // Rename: next two NUL-separated tokens are oldPath, newPath.
            _ = scanner.next() // oldPath
            path = scanner.next() ?? ""
        }
        guard !path.isEmpty else { continue }
        map[path] = NumstatEntry(additions: adds, deletions: dels, isBinary: isBin)
    }
    return map
}

private struct NameStatusEntry {
    let path: String
    let oldPath: String?
    let changeType: GitDiffChangeType
}

private func parseNameStatus(_ raw: String) -> [NameStatusEntry] {
    var result: [NameStatusEntry] = []
    let scanner = NulScanner(raw)
    while let status = scanner.next() {
        if status.isEmpty { continue }
        let changeType = GitDiffChangeType.parse(status)
        if changeType == .renamed || changeType == .copied {
            guard let oldPath = scanner.next(), let newPath = scanner.next() else { continue }
            result.append(NameStatusEntry(path: newPath, oldPath: oldPath, changeType: changeType))
        } else {
            guard let path = scanner.next() else { continue }
            result.append(NameStatusEntry(path: path, oldPath: nil, changeType: changeType))
        }
    }
    return result
}

// MARK: - Side-by-side parsing

enum SideBySideLineKind: Sendable, Equatable {
    case context
    case added
    case deleted
    case empty
    case hunk
    case commentPlaceholder
    /// `<<<<<<<` marker (start of "ours" in a merge conflict).
    case conflictOurs
    /// `|||||||` marker (base in diff3 conflict style).
    case conflictBase
    /// `=======` separator between ours/theirs.
    case conflictSeparator
    /// `>>>>>>>` marker (end of "theirs").
    case conflictTheirs
}

/// Returns the conflict-marker kind for a raw content line (without the
/// leading `+`/`-`/space diff prefix), or `nil` if the line is not a marker.
func conflictMarkerKind(forContent content: String) -> SideBySideLineKind? {
    if content.hasPrefix("<<<<<<<") { return .conflictOurs }
    if content.hasPrefix("|||||||") { return .conflictBase }
    if content.hasPrefix(">>>>>>>") { return .conflictTheirs }
    // `=======` is also used inside docstrings/setext underlines, so we
    // require the line to be only `=` characters (allowing optional trailing
    // label like `======= HEAD`).
    if content.hasPrefix("=======") {
        let body = content.dropFirst(7)
        if body.isEmpty || body.first == " " { return .conflictSeparator }
    }
    return nil
}

struct SideBySideCell: Sendable {
    let lineNumber: Int?
    let content: String
    let kind: SideBySideLineKind
    var intraLineRanges: [NSRange] = []
}

enum SideBySideRow: Identifiable, Sendable {
    case hunkHeader(id: Int, text: String)
    case pair(id: Int, left: SideBySideCell, right: SideBySideCell)

    var id: Int {
        switch self {
        case .hunkHeader(let id, _): return id
        case .pair(let id, _, _): return id
        }
    }
}

func parseSideBySideRows(from diff: String) -> [SideBySideRow] {
    var rows: [SideBySideRow] = []
    var oldLine = 0
    var newLine = 0
    var delQueue: [SideBySideCell] = []
    var addQueue: [SideBySideCell] = []
    var nextId = 0

    func emptyCell() -> SideBySideCell {
        SideBySideCell(lineNumber: nil, content: "", kind: .empty)
    }

    func flushQueues() {
        let maxCount = max(delQueue.count, addQueue.count)
        if maxCount == 0 { return }
        for i in 0..<maxCount {
            var left = i < delQueue.count ? delQueue[i] : emptyCell()
            var right = i < addQueue.count ? addQueue[i] : emptyCell()
            if left.kind == .deleted && right.kind == .added {
                let token = computeTokenDiff(left.content, right.content)
                left.intraLineRanges = token.leftRanges
                right.intraLineRanges = token.rightRanges
            }
            rows.append(.pair(id: nextId, left: left, right: right))
            nextId += 1
        }
        delQueue.removeAll()
        addQueue.removeAll()
    }

    let lines = diff.components(separatedBy: "\n")
    for line in lines {
        if line.hasPrefix("@@") {
            flushQueues()
            rows.append(.hunkHeader(id: nextId, text: line))
            nextId += 1
            if let (oldStart, newStart) = parseHunkHeader(line) {
                oldLine = oldStart
                newLine = newStart
            }
            continue
        }
        if line.hasPrefix("---") || line.hasPrefix("+++")
            || line.hasPrefix("diff ") || line.hasPrefix("index ")
            || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
            || line.hasPrefix("old mode") || line.hasPrefix("new mode")
            || line.hasPrefix("similarity ") || line.hasPrefix("rename ")
            || line.hasPrefix("copy ") || line.hasPrefix("Binary ") {
            continue
        }
        if line.hasPrefix("\\") {
            // "\ No newline at end of file" — skip
            continue
        }
        if line.hasPrefix(" ") || line.isEmpty {
            flushQueues()
            let content = line.isEmpty ? "" : String(line.dropFirst())
            let kind: SideBySideLineKind = conflictMarkerKind(forContent: content) ?? .context
            rows.append(.pair(
                id: nextId,
                left: SideBySideCell(lineNumber: oldLine, content: content, kind: kind),
                right: SideBySideCell(lineNumber: newLine, content: content, kind: kind)
            ))
            nextId += 1
            oldLine += 1
            newLine += 1
            continue
        }
        if line.hasPrefix("-") {
            let content = String(line.dropFirst())
            let kind: SideBySideLineKind = conflictMarkerKind(forContent: content) ?? .deleted
            delQueue.append(SideBySideCell(lineNumber: oldLine, content: content, kind: kind))
            oldLine += 1
            continue
        }
        if line.hasPrefix("+") {
            let content = String(line.dropFirst())
            let kind: SideBySideLineKind = conflictMarkerKind(forContent: content) ?? .added
            addQueue.append(SideBySideCell(lineNumber: newLine, content: content, kind: kind))
            newLine += 1
            continue
        }
    }
    flushQueues()
    return rows
}

/// Parses `@@ -A[,B] +C[,D] @@` and returns (oldStart, newStart).
private func parseHunkHeader(_ header: String) -> (Int, Int)? {
    guard header.hasPrefix("@@") else { return nil }
    let parts = header.split(separator: " ")
    guard parts.count >= 3 else { return nil }
    let left = parts[1]  // "-A,B" or "-A"
    let right = parts[2] // "+C,D" or "+C"
    func parse(_ s: Substring, prefix: Character) -> Int? {
        guard s.first == prefix else { return nil }
        let body = s.dropFirst()
        let nums = body.split(separator: ",")
        guard let first = nums.first, let n = Int(first) else { return nil }
        return n
    }
    guard let a = parse(left, prefix: "-"), let b = parse(right, prefix: "+") else {
        return nil
    }
    return (a, b)
}

// MARK: - Connector segments (IntelliJ-style ribbons)

/// One change region linking the left and right panes. Built from the
/// per-line `SideBySideLineKind` arrays produced for the side-by-side view.
///
/// `leftLineRange` / `rightLineRange` index into the parallel `*LineStarts`
/// arrays. An empty range means the side has no real lines for this segment
/// (pure insertion or pure deletion); the renderer collapses that endpoint
/// to a point at the gap between surrounding context.
struct DiffConnectorSegment: Equatable, Sendable {
    enum Kind: Sendable {
        case added
        case deleted
        case changed
        case moved
    }

    let kind: Kind
    /// Range in the left side's `leftLineStarts` array. Empty when the change
    /// is a pure addition (no left content); the renderer collapses the left
    /// endpoint to a single Y at `leftAnchorRow`'s top.
    let leftLineRange: Range<Int>
    let rightLineRange: Range<Int>
    /// For an empty `leftLineRange`, the row in `leftLineStarts` that should
    /// host the funnel apex (the row right after the gap, i.e., the next
    /// context line on the left). Equals `leftLineStarts.count` when the gap
    /// sits at the very end of the file. Symmetric for the right side.
    let leftAnchorRow: Int
    let rightAnchorRow: Int
    /// Same value on both ends of a moved pair, so the renderer can pair
    /// them without reusing identifiers from other segment types.
    let movePartnerID: Int?
}

/// Build connector segments from the parallel pair-level kind arrays plus
/// the per-pair side row indices (nil when that side is empty for the pair).
///
/// `pairLeftRows[i]` / `pairRightRows[i]` give the row position in the side's
/// own `leftLineStarts` / `rightLineStarts` arrays. Empty-side pairs are
/// represented by `nil`, and the resulting segment's `leftLineRange` /
/// `rightLineRange` will be empty for that side. The renderer pins the
/// collapsed endpoint of the funnel to `leftAnchorRow` / `rightAnchorRow` —
/// the next non-empty row on that side after the run.
///
/// Move detection (when `detectMoves` is true) hashes the trimmed content of
/// each `.added`/`.deleted` run and pairs runs with identical content
/// elsewhere in the file. Pairs become `.moved` segments; unpaired runs keep
/// their original kind.
func buildConnectorSegments(
    pairLeftKinds: [SideBySideLineKind],
    pairRightKinds: [SideBySideLineKind],
    pairLeftRows: [Int?],
    pairRightRows: [Int?],
    leftAttr: NSAttributedString,
    rightAttr: NSAttributedString,
    leftLineStarts: [Int],
    rightLineStarts: [Int],
    detectMoves: Bool = true
) -> [DiffConnectorSegment] {
    let count = min(min(pairLeftKinds.count, pairRightKinds.count),
                    min(pairLeftRows.count, pairRightRows.count))
    guard count > 0 else { return [] }

    func isChange(_ l: SideBySideLineKind, _ r: SideBySideLineKind) -> Bool {
        switch (l, r) {
        case (.context, .context),
             (.context, .empty), (.empty, .context),
             (.empty, .empty),
             (.commentPlaceholder, _), (_, .commentPlaceholder):
            return false
        default:
            return true
        }
    }

    func nextLeftRow(after pairIdx: Int) -> Int {
        var j = pairIdx
        while j < count {
            if let r = pairLeftRows[j] { return r }
            j += 1
        }
        return leftLineStarts.count
    }
    func nextRightRow(after pairIdx: Int) -> Int {
        var j = pairIdx
        while j < count {
            if let r = pairRightRows[j] { return r }
            j += 1
        }
        return rightLineStarts.count
    }

    struct RawSegment {
        let leftRange: Range<Int>
        let rightRange: Range<Int>
        let leftAnchor: Int
        let rightAnchor: Int
    }

    var rawSegments: [RawSegment] = []
    var i = 0
    while i < count {
        if !isChange(pairLeftKinds[i], pairRightKinds[i]) {
            i += 1
            continue
        }
        let runStart = i
        while i < count && isChange(pairLeftKinds[i], pairRightKinds[i]) {
            i += 1
        }
        let runRange = runStart..<i

        var leftRows: [Int] = []
        var rightRows: [Int] = []
        for k in runRange {
            if let lr = pairLeftRows[k] { leftRows.append(lr) }
            if let rr = pairRightRows[k] { rightRows.append(rr) }
        }
        let leftRange: Range<Int>
        if let lo = leftRows.first, let hi = leftRows.last {
            leftRange = lo..<(hi + 1)
        } else {
            leftRange = 0..<0
        }
        let rightRange: Range<Int>
        if let lo = rightRows.first, let hi = rightRows.last {
            rightRange = lo..<(hi + 1)
        } else {
            rightRange = 0..<0
        }
        // Anchor for the empty side: the next real row past the run, or the
        // last left/right row when the run sits at the end of the file. The
        // renderer pins the funnel apex to this row's top edge.
        let leftAnchor = leftRange.isEmpty ? nextLeftRow(after: runRange.upperBound) : leftRange.lowerBound
        let rightAnchor = rightRange.isEmpty ? nextRightRow(after: runRange.upperBound) : rightRange.lowerBound
        rawSegments.append(RawSegment(
            leftRange: leftRange,
            rightRange: rightRange,
            leftAnchor: leftAnchor,
            rightAnchor: rightAnchor
        ))
    }

    let leftString = leftAttr.string as NSString
    let rightString = rightAttr.string as NSString

    func slice(_ s: NSString, _ starts: [Int], _ range: Range<Int>) -> String {
        guard !range.isEmpty, range.lowerBound < starts.count else { return "" }
        let start = starts[range.lowerBound]
        let end: Int
        if range.upperBound < starts.count {
            end = starts[range.upperBound]
        } else {
            end = s.length
        }
        if end <= start { return "" }
        return s.substring(with: NSRange(location: start, length: end - start))
    }

    func normalize(_ raw: String) -> String {
        var lines: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        return lines.joined(separator: "\n")
    }

    var segments: [DiffConnectorSegment] = []
    var deletedSlots: [String: [Int]] = [:]
    var addedSlots: [String: [Int]] = [:]

    for raw in rawSegments {
        let leftHasContent = !raw.leftRange.isEmpty
        let rightHasContent = !raw.rightRange.isEmpty
        let kind: DiffConnectorSegment.Kind
        if leftHasContent && rightHasContent {
            kind = .changed
        } else if rightHasContent {
            kind = .added
        } else if leftHasContent {
            kind = .deleted
        } else {
            continue
        }
        let segmentIdx = segments.count
        let segment = DiffConnectorSegment(
            kind: kind,
            leftLineRange: raw.leftRange,
            rightLineRange: raw.rightRange,
            leftAnchorRow: raw.leftAnchor,
            rightAnchorRow: raw.rightAnchor,
            movePartnerID: nil
        )
        segments.append(segment)

        if detectMoves {
            if kind == .added {
                let key = normalize(slice(rightString, rightLineStarts, raw.rightRange))
                if !key.isEmpty {
                    addedSlots[key, default: []].append(segmentIdx)
                }
            } else if kind == .deleted {
                let key = normalize(slice(leftString, leftLineStarts, raw.leftRange))
                if !key.isEmpty {
                    deletedSlots[key, default: []].append(segmentIdx)
                }
            }
        }
    }

    if detectMoves {
        var nextMoveID = 0
        for (key, addedList) in addedSlots {
            guard let deletedList = deletedSlots[key] else { continue }
            let pairs = min(addedList.count, deletedList.count)
            guard pairs > 0 else { continue }
            for p in 0..<pairs {
                let aPos = addedList[p]
                let dPos = deletedList[p]
                let movedID = nextMoveID
                nextMoveID += 1
                let added = segments[aPos]
                let deleted = segments[dPos]
                segments[aPos] = DiffConnectorSegment(
                    kind: .moved,
                    leftLineRange: deleted.leftLineRange,
                    rightLineRange: added.rightLineRange,
                    leftAnchorRow: deleted.leftAnchorRow,
                    rightAnchorRow: added.rightAnchorRow,
                    movePartnerID: movedID
                )
                segments[dPos] = DiffConnectorSegment(
                    kind: .moved,
                    leftLineRange: deleted.leftLineRange,
                    rightLineRange: added.rightLineRange,
                    leftAnchorRow: deleted.leftAnchorRow,
                    rightAnchorRow: added.rightAnchorRow,
                    movePartnerID: movedID
                )
            }
        }
        // Deduplicate: each move pair was written into both slots; collapse to
        // a single segment per partner ID for the renderer.
        var seenMoveIDs = Set<Int>()
        var deduped: [DiffConnectorSegment] = []
        deduped.reserveCapacity(segments.count)
        for seg in segments {
            if let id = seg.movePartnerID {
                if seenMoveIDs.insert(id).inserted {
                    deduped.append(seg)
                }
            } else {
                deduped.append(seg)
            }
        }
        segments = deduped
    }

    return segments
}

// MARK: - 3-way conflict viewer

/// The three blobs needed to render a merge conflict as ours | base | theirs.
/// Each blob is `nil` when the file isn't present in that ref (added on one
/// side, deleted on the other, or the merge-base couldn't be computed). The
/// labels are display strings derived from the spec branches.
struct ThreeWayBlobs: Sendable, Equatable {
    let ours: String?
    let base: String?
    let theirs: String?
    let oursLabel: String
    let baseLabel: String
    let theirsLabel: String
}

/// Fetches the three blobs for a conflicting file: ours = `git show <base>:<path>`,
/// theirs = `git show <compare>:<path>`, base = `git show <merge-base>:<path>`.
/// Returns `nil` when `spec.compare == nil` or no merge-base can be computed
/// (caller should fall back to the existing 2-pane merged-with-markers view).
func fetchOursBaseTheirs(spec: GitDiffSpec, file: GitDiffFile) async throws -> ThreeWayBlobs? {
    guard spec.compare != nil else { return nil }
    let resolved = try await resolveSpecRefs(spec)
    guard let compareRef = resolved.compare else { return nil }
    let oursRef = resolved.base
    let theirsRef = compareRef

    // merge-base. Failure (no common ancestor, octopus, etc.) returns nil so
    // the caller degrades gracefully to the side-by-side merged view.
    let mergeBaseResult = try? await runGitAllowingNonZero(
        args: ["merge-base", oursRef, theirsRef],
        directory: spec.directory
    )
    let mergeBase: String?
    if let r = mergeBaseResult, r.status == 0,
       let s = String(data: r.stdout, encoding: .utf8) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        mergeBase = trimmed.isEmpty ? nil : trimmed
    } else {
        mergeBase = nil
    }

    let path = file.path
    let oldPath = file.oldPath

    async let oursBlob = gitShowBlob(
        ref: oursRef, path: path, fallbackPath: oldPath, directory: spec.directory
    )
    async let theirsBlob = gitShowBlob(
        ref: theirsRef, path: path, fallbackPath: oldPath, directory: spec.directory
    )
    async let baseBlob: String? = {
        guard let mb = mergeBase else { return nil }
        return await gitShowBlob(
            ref: mb, path: path, fallbackPath: oldPath, directory: spec.directory
        )
    }()

    let ours = await oursBlob
    let theirs = await theirsBlob
    let base = await baseBlob

    return ThreeWayBlobs(
        ours: ours,
        base: base,
        theirs: theirs,
        oursLabel: spec.base,
        baseLabel: String(localized: "diff.threeWay.baseLabel", defaultValue: "merge-base"),
        theirsLabel: spec.compare ?? ""
    )
}

/// `git show <ref>:<path>` returning nil on any non-zero exit. Tries
/// `fallbackPath` (typically `file.oldPath` for renames) when the primary
/// path is absent in the given ref.
private func gitShowBlob(
    ref: String,
    path: String,
    fallbackPath: String?,
    directory: String
) async -> String? {
    if let s = await tryGitShow(ref: ref, path: path, directory: directory) {
        return s
    }
    if let alt = fallbackPath, alt != path,
       let s = await tryGitShow(ref: ref, path: alt, directory: directory) {
        return s
    }
    return nil
}

private func tryGitShow(ref: String, path: String, directory: String) async -> String? {
    guard let result = try? await runGitAllowingNonZero(
        args: ["show", "\(ref):\(path)"],
        directory: directory
    ) else { return nil }
    guard result.status == 0 else { return nil }
    return String(data: result.stdout, encoding: .utf8)
}

/// Iterates over NUL-delimited fields.
private final class NulScanner {
    private let chars: [Substring]
    private var index: Int = 0

    init(_ input: String) {
        self.chars = input.split(separator: "\0", omittingEmptySubsequences: false)
    }

    func next() -> String? {
        guard index < chars.count else { return nil }
        defer { index += 1 }
        return String(chars[index])
    }
}
