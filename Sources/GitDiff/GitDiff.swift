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
private func resolveSpecRefs(_ spec: GitDiffSpec) async throws -> (base: String, compare: String?) {
    let remote = gitDiffDefaultRemote
    let resolvedBase = await resolveRef(spec.base, directory: spec.directory, remote: remote)
    var resolvedCompare: String? = nil
    if let compare = spec.compare {
        resolvedCompare = await resolveRef(compare, directory: spec.directory, remote: remote)
    }

    var missing: [String] = []
    if resolvedBase == nil { missing.append(spec.base) }
    if let compare = spec.compare, resolvedCompare == nil { missing.append(compare) }
    if !missing.isEmpty {
        gitDiffDebugLog("missing refs base=\(spec.base) compare=\(spec.compare ?? "-") missing=\(missing) remote=\(remote) dir=\(spec.directory)")
        throw GitDiffError.missingRefs(branches: missing, remote: remote)
    }

    return (resolvedBase!, resolvedCompare)
}

/// Resolve the `spec`'s refs to ones that exist locally, preferring the
/// remote-tracking branch. Throws `missingRefs` if any side can't be resolved
/// so the UI can surface a fetch-and-retry action.
private func resolvedRangeArgs(for spec: GitDiffSpec) async throws -> [String] {
    let resolved = try await resolveSpecRefs(spec)
    if let compare = resolved.compare {
        let range = "\(resolved.base)...\(compare)"
        gitDiffDebugLog("range base=\(spec.base) -> \(resolved.base) compare=\(spec.compare ?? "-") -> \(compare) args=\(range) dir=\(spec.directory)")
        return [range]
    }
    gitDiffDebugLog("range single base=\(spec.base) -> \(resolved.base) dir=\(spec.directory)")
    return [resolved.base]
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
    let numstat: String
    let nameStatus: String
    do {
        numstat = try await runGit(
            args: ["diff", "--numstat", "-z"] + rangeArgs + ["--"],
            directory: spec.directory
        )
        nameStatus = try await runGit(
            args: ["diff", "--name-status", "-z"] + rangeArgs + ["--"],
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
