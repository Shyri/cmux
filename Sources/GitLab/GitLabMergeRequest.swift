import Foundation

// MARK: - Model

struct GitLabReviewer: Equatable, Hashable, Sendable {
    let name: String
    let username: String
}

struct GitLabMergeRequest: Identifiable, Equatable, Sendable {
    let id: Int
    let iid: Int
    let projectId: Int
    let title: String
    let state: String
    let authorName: String
    let authorUsername: String
    let webURL: String
    let sourceBranch: String
    let targetBranch: String
    let labels: [String]
    let isDraft: Bool
    let createdAt: Date?
    let updatedAt: Date?
    let reviewers: [GitLabReviewer]
    /// Mutated optimistically by `MergeRequestsState.setAssignee` while a
    /// `glab mr update` round-trip is in flight; reconciled on refresh.
    var assignees: [GitLabReviewer]
    let userNotesCount: Int
    /// Raw GitLab `merge_status` (`can_be_merged`, `cannot_be_merged`, …).
    let mergeStatus: String
    /// True when the GitLab `has_conflicts` flag is set on the MR.
    let hasConflicts: Bool
    /// Approval info fetched lazily from
    /// `projects/:id/merge_requests/:iid/approvals`. `nil` means not loaded yet.
    var approval: GitLabMRApproval?
}

struct GitLabMRApproval: Equatable, Sendable {
    let approved: Bool
    let approvalsRequired: Int
    let approvalsLeft: Int
    let approvedBy: [GitLabReviewer]
}

// MARK: - JSON Decoding (glab mr list -F json)

private struct GLMRAuthor: Decodable {
    let name: String?
    let username: String?
}

private struct GLMRResponse: Decodable {
    let id: Int
    let iid: Int
    let project_id: Int?
    let title: String
    let state: String
    let author: GLMRAuthor?
    let web_url: String?
    let source_branch: String?
    let target_branch: String?
    let labels: [String]?
    let draft: Bool?
    let created_at: String?
    let updated_at: String?
    let reviewers: [GLMRAuthor]?
    let assignees: [GLMRAuthor]?
    let user_notes_count: Int?
    let merge_status: String?
    let has_conflicts: Bool?

    func toModel() -> GitLabMergeRequest {
        GitLabMergeRequest(
            id: id,
            iid: iid,
            projectId: project_id ?? 0,
            title: title,
            state: state,
            authorName: author?.name ?? "",
            authorUsername: author?.username ?? "",
            webURL: web_url ?? "",
            sourceBranch: source_branch ?? "",
            targetBranch: target_branch ?? "",
            labels: labels ?? [],
            isDraft: draft ?? false,
            createdAt: Self.parseDate(created_at),
            updatedAt: Self.parseDate(updated_at),
            reviewers: (reviewers ?? []).map {
                GitLabReviewer(name: $0.name ?? "", username: $0.username ?? "")
            },
            assignees: (assignees ?? []).map {
                GitLabReviewer(name: $0.name ?? "", username: $0.username ?? "")
            },
            userNotesCount: user_notes_count ?? 0,
            mergeStatus: merge_status ?? "",
            hasConflicts: has_conflicts ?? false,
            approval: nil
        )
    }

    private static func parseDate(_ str: String?) -> Date? {
        guard let str else { return nil }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: str) { return d }
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: str)
    }
}

// MARK: - Fetcher

enum GitLabMRFetchError: Error, Sendable {
    case glabNotFound
    case notGitLabRepo
    case processError(String)
    case parseError
}

/// Runs `glab mr list -F json` in the given directory and returns parsed MRs.
func fetchGitLabMergeRequests(
    in directory: String,
    perPage: Int = 20
) async throws -> [GitLabMergeRequest] {
    // Find glab binary
    let glabPath = findGlabPath()
    guard let glabPath else { throw GitLabMRFetchError.glabNotFound }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: glabPath)
    process.arguments = ["mr", "list", "-F", "json", "--per-page", "\(perPage)"]
    process.currentDirectoryURL = URL(fileURLWithPath: directory)

    // Inherit user PATH so glab can find git and its config
    var env = ProcessInfo.processInfo.environment
    env["NO_COLOR"] = "1"
    process.environment = env

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    let (outData, errData) = drainPipesInParallel(stdout: stdout, stderr: stderr)
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        if errStr.contains("None of the git remotes") || errStr.contains("not a git repository") {
            throw GitLabMRFetchError.notGitLabRepo
        }
        throw GitLabMRFetchError.processError(errStr)
    }

    guard !outData.isEmpty else { return [] }

    let decoder = JSONDecoder()
    let responses = try decoder.decode([GLMRResponse].self, from: outData)
    return responses.map { $0.toModel() }
}

/// Runs `glab mr approve <iid>` in `directory`. Returns glab's stdout+stderr
/// concatenated on success, throws `GitLabMRFetchError.processError` with the
/// captured error output otherwise.
func approveGitLabMergeRequest(iid: Int, directory: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let output = try runGlabApprove(iid: iid, directory: directory)
                continuation.resume(returning: output)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private func runGlabApprove(iid: Int, directory: String) throws -> String {
    guard let glabPath = findGlabPath() else {
        throw GitLabMRFetchError.glabNotFound
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: glabPath)
    process.arguments = ["mr", "approve", "\(iid)"]
    process.currentDirectoryURL = URL(fileURLWithPath: directory)

    var env = ProcessInfo.processInfo.environment
    env["NO_COLOR"] = "1"
    process.environment = env

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    let (outData, errData) = drainPipesInParallel(stdout: stdout, stderr: stderr)
    process.waitUntilExit()

    let outStr = String(data: outData, encoding: .utf8) ?? ""
    let errStr = String(data: errData, encoding: .utf8) ?? ""

    if process.terminationStatus != 0 {
        let combined = [errStr, outStr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        throw GitLabMRFetchError.processError(combined.isEmpty ? "glab mr approve failed" : combined)
    }
    return [outStr, errStr]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

// MARK: - Assignee mutation

/// Replaces the MR's sole assignee with `username`. Passing `nil` clears the
/// assignee list. Uses `glab mr update` so we can address users by handle —
/// the panel doesn't always know a user's numeric id (e.g. when they only
/// appeared as a reviewer on a sibling MR) and `glab` does the username →
/// user lookup for us.
func updateGitLabMRAssignee(
    iid: Int,
    assigneeUsername: String?,
    in directory: String
) async throws {
    guard let glabPath = findGlabPath() else {
        throw GitLabMRFetchError.glabNotFound
    }

    var arguments: [String] = ["mr", "update", "\(iid)"]
    if let username = assigneeUsername, !username.isEmpty {
        // `glab mr update --assignee` wants the bare GitLab handle — passing
        // `@<username>` makes glab search for a literal user named "@…" and
        // fail with "Failed to find user by name".
        arguments.append(contentsOf: ["--assignee", username])
    } else {
        arguments.append("--unassign")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: glabPath)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: directory)

    var env = ProcessInfo.processInfo.environment
    env["NO_COLOR"] = "1"
    process.environment = env

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    let (outData, errData) = drainPipesInParallel(stdout: stdout, stderr: stderr)
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        let combined = [errStr, outStr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        throw GitLabMRFetchError.processError(
            combined.isEmpty ? "glab mr update failed" : combined
        )
    }
}

// MARK: - Approvals

private struct GLMRApprovalResponse: Decodable {
    struct ApprovedByEntry: Decodable {
        let user: GLMRAuthor?
    }
    let approved: Bool?
    let approvals_required: Int?
    let approvals_left: Int?
    let approved_by: [ApprovedByEntry]?
}

/// Runs `glab api projects/:projectId/merge_requests/:iid/approvals` in
/// `directory` and returns the parsed approval state.
func fetchGitLabMRApproval(
    projectId: Int,
    iid: Int,
    in directory: String
) async throws -> GitLabMRApproval {
    guard let glabPath = findGlabPath() else {
        throw GitLabMRFetchError.glabNotFound
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: glabPath)
    process.arguments = [
        "api",
        "projects/\(projectId)/merge_requests/\(iid)/approvals",
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: directory)

    var env = ProcessInfo.processInfo.environment
    env["NO_COLOR"] = "1"
    process.environment = env

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    let (outData, errData) = drainPipesInParallel(stdout: stdout, stderr: stderr)
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        throw GitLabMRFetchError.processError(errStr)
    }

    let decoded = try JSONDecoder().decode(GLMRApprovalResponse.self, from: outData)
    return GitLabMRApproval(
        approved: decoded.approved ?? false,
        approvalsRequired: decoded.approvals_required ?? 0,
        approvalsLeft: decoded.approvals_left ?? 0,
        approvedBy: (decoded.approved_by ?? []).compactMap { entry in
            guard let u = entry.user else { return nil }
            return GitLabReviewer(name: u.name ?? "", username: u.username ?? "")
        }
    )
}

