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

/// Resolve the `spec`'s refs to ones that exist locally, preferring the
/// remote-tracking branch. Throws `missingRefs` if any side can't be resolved
/// so the UI can surface a fetch-and-retry action.
private func resolvedRangeArgs(for spec: GitDiffSpec) async throws -> [String] {
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
        throw GitDiffError.missingRefs(branches: missing, remote: remote)
    }

    if let resolvedCompare {
        return ["\(resolvedBase!)...\(resolvedCompare)"]
    }
    return [resolvedBase!]
}

func fetchGitBranches(_ branches: [String], remote: String, directory: String) async throws {
    guard !branches.isEmpty else { return }
    _ = try await runGit(
        args: ["fetch", "--no-tags", remote] + branches,
        directory: directory
    )
}

// MARK: - Fetchers

func fetchChangedFiles(spec: GitDiffSpec) async throws -> [GitDiffFile] {
    let rangeArgs = try await resolvedRangeArgs(for: spec)
    let numstat = try await runGit(
        args: ["diff", "--numstat", "-z"] + rangeArgs,
        directory: spec.directory
    )
    let nameStatus = try await runGit(
        args: ["diff", "--name-status", "-z"] + rangeArgs,
        directory: spec.directory
    )

    let stats = parseNumstat(numstat)
    let statuses = parseNameStatus(nameStatus)

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
    return try await runGit(args: args, directory: spec.directory, stringOutput: true)
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
            rows.append(.pair(
                id: nextId,
                left: SideBySideCell(lineNumber: oldLine, content: content, kind: .context),
                right: SideBySideCell(lineNumber: newLine, content: content, kind: .context)
            ))
            nextId += 1
            oldLine += 1
            newLine += 1
            continue
        }
        if line.hasPrefix("-") {
            let content = String(line.dropFirst())
            delQueue.append(SideBySideCell(lineNumber: oldLine, content: content, kind: .deleted))
            oldLine += 1
            continue
        }
        if line.hasPrefix("+") {
            let content = String(line.dropFirst())
            addQueue.append(SideBySideCell(lineNumber: newLine, content: content, kind: .added))
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
