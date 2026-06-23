import Foundation

// MARK: - Model

struct GitLabMilestone: Equatable, Hashable, Sendable {
    let id: Int
    let title: String
    let state: String
    let dueDate: Date?
}

struct GitLabAssignee: Equatable, Hashable, Sendable {
    let name: String
    let username: String
}

/// Lightweight project-label payload — the side panel uses this to paint
/// each label chip with its real GitLab colour instead of the generic
/// `.secondary.opacity(0.12)` placeholder.
struct GitLabLabel: Equatable, Hashable, Sendable {
    let name: String
    /// Background colour as returned by the API, e.g. `"#ed9121"`.
    let color: String
    /// Foreground/text colour the GitLab UI uses on top of `color`,
    /// e.g. `"#FFFFFF"`. Always paired with `color` so contrast matches
    /// what users see in the GitLab web UI.
    let textColor: String
}

struct GitLabIssue: Identifiable, Equatable, Sendable {
    let id: Int
    let iid: Int
    let projectId: Int
    let title: String
    let state: String
    let authorName: String
    let authorUsername: String
    let webURL: String
    let labels: [String]
    let milestone: GitLabMilestone?
    /// Mutated optimistically by `IssuesState.setAssignee` while a
    /// `glab issue update` round-trip is in flight; reconciled on refresh.
    var assignees: [GitLabAssignee]
    let userNotesCount: Int
    let createdAt: Date?
    let updatedAt: Date?
    /// Count of open merge requests related to this issue. `nil` means not
    /// loaded yet (lazy fetch via
    /// `projects/:id/issues/:iid/related_merge_requests`).
    var relatedOpenMRsCount: Int?
}

// MARK: - JSON Decoding (glab issue list -F json)

private struct GLIssueAuthor: Decodable {
    let name: String?
    let username: String?
}

private struct GLIssueMilestone: Decodable {
    let id: Int?
    let title: String?
    let state: String?
    let due_date: String?
}

private struct GLIssueResponse: Decodable {
    let id: Int?
    let iid: Int?
    let project_id: Int?
    let title: String?
    let state: String?
    let author: GLIssueAuthor?
    let web_url: String?
    let labels: [String]?
    let milestone: GLIssueMilestone?
    let assignees: [GLIssueAuthor]?
    let user_notes_count: Int?
    let created_at: String?
    let updated_at: String?

    func toModel() -> GitLabIssue {
        let ms: GitLabMilestone?
        if let m = milestone, let title = m.title, !title.isEmpty {
            ms = GitLabMilestone(
                id: m.id ?? 0,
                title: title,
                state: m.state ?? "",
                dueDate: Self.parseDate(m.due_date)
            )
        } else {
            ms = nil
        }

        return GitLabIssue(
            id: id ?? 0,
            iid: iid ?? 0,
            projectId: project_id ?? 0,
            title: title ?? "",
            state: state ?? "opened",
            authorName: author?.name ?? "",
            authorUsername: author?.username ?? "",
            webURL: web_url ?? "",
            labels: labels ?? [],
            milestone: ms,
            assignees: (assignees ?? []).compactMap { a in
                let username = a.username ?? ""
                let name = a.name ?? ""
                guard !username.isEmpty || !name.isEmpty else { return nil }
                return GitLabAssignee(name: name, username: username)
            },
            userNotesCount: user_notes_count ?? 0,
            createdAt: Self.parseDate(created_at),
            updatedAt: Self.parseDate(updated_at),
            relatedOpenMRsCount: nil
        )
    }

    private static func parseDate(_ str: String?) -> Date? {
        guard let str else { return nil }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: str) { return d }
        fmt.formatOptions = [.withInternetDateTime]
        if let d = fmt.date(from: str) { return d }
        // Fall back to yyyy-MM-dd for milestone due_date
        let dateOnly = DateFormatter()
        dateOnly.calendar = Calendar(identifier: .iso8601)
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.timeZone = TimeZone(identifier: "UTC")
        return dateOnly.date(from: str)
    }
}

extension GitLabIssue {
    /// Decode a `glab issue list -F json` payload into models. Split out of
    /// `fetchGitLabIssues` so the field mapping (milestone, assignees,
    /// labels, date parsing) is unit-testable without spawning `glab`.
    static func decodeList(from data: Data) throws -> [GitLabIssue] {
        try JSONDecoder().decode([GLIssueResponse].self, from: data).map { $0.toModel() }
    }
}

// MARK: - Fetcher

enum GitLabIssueFetchError: Error, Sendable {
    case glabNotFound
    case notGitLabRepo
    case processError(String)
    case parseError
}

func fetchGitLabIssues(
    in directory: String,
    perPage: Int = 100,
    maxPages: Int = 10
) async throws -> [GitLabIssue] {
    let glabPath = findGlabPath()
    guard let glabPath else { throw GitLabIssueFetchError.glabNotFound }

    var all: [GitLabIssue] = []
    var page = 1
    // `glab issue list` defaults to sort=created_at desc, per-page=30. With
    // many open issues this drops anything older than the top window — the
    // side panel was showing only the newest few issues even though older
    // ones were still in "opened" state. We page through up to
    // `perPage * maxPages` issues, which covers all realistic active
    // projects without unbounded paging on giant trackers.
    while page <= maxPages {
        let pageIssues = try await fetchGitLabIssuesPage(
            glabPath: glabPath,
            directory: directory,
            perPage: perPage,
            page: page
        )
        all.append(contentsOf: pageIssues)
        if pageIssues.count < perPage { break }
        page += 1
    }
    return all
}

private func fetchGitLabIssuesPage(
    glabPath: String,
    directory: String,
    perPage: Int,
    page: Int
) async throws -> [GitLabIssue] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: glabPath)
    process.arguments = [
        "issue", "list",
        "-O", "json",
        "--per-page", "\(perPage)",
        "--page", "\(page)"
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
        if errStr.contains("None of the git remotes") || errStr.contains("not a git repository") {
            throw GitLabIssueFetchError.notGitLabRepo
        }
        throw GitLabIssueFetchError.processError(errStr)
    }

    guard !outData.isEmpty else { return [] }

    // Trim any non-JSON prefix (some glab versions print warnings before JSON).
    let trimmedData = trimmingNonJSONPrefix(outData)

    let decoder = JSONDecoder()
    do {
        let responses = try decoder.decode([GLIssueResponse].self, from: trimmedData)
        return responses.map { $0.toModel() }
    } catch {
        let preview = String(data: trimmedData.prefix(300), encoding: .utf8) ?? "<non-utf8>"
        throw GitLabIssueFetchError.processError("Decode error: \(error.localizedDescription)\nOutput: \(preview)")
    }
}

// MARK: - Assignee mutation

/// Replaces the issue's sole assignee with `username`. Passing `nil` clears
/// the assignee list. Uses `glab issue update` so users can be addressed by
/// handle even when their numeric id hasn't been fetched yet.
func updateGitLabIssueAssignee(
    iid: Int,
    assigneeUsername: String?,
    in directory: String
) async throws {
    guard let glabPath = findGlabPath() else {
        throw GitLabIssueFetchError.glabNotFound
    }

    var arguments: [String] = ["issue", "update", "\(iid)"]
    if let username = assigneeUsername, !username.isEmpty {
        // `glab issue update --assignee` wants the bare GitLab handle —
        // passing `@<username>` makes glab look for a literal user named
        // "@…" and fail with "Failed to find user by name".
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
        throw GitLabIssueFetchError.processError(
            combined.isEmpty ? "glab issue update failed" : combined
        )
    }
}

// MARK: - Related Merge Requests

private struct GLRelatedMRResponse: Decodable {
    let state: String?
}

/// Runs `glab api projects/:projectId/issues/:iid/related_merge_requests` and
/// returns the count of merge requests in the `opened` state.
func fetchGitLabIssueOpenRelatedMRsCount(
    projectId: Int,
    iid: Int,
    in directory: String
) async throws -> Int {
    guard let glabPath = findGlabPath() else {
        throw GitLabIssueFetchError.glabNotFound
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: glabPath)
    process.arguments = [
        "api",
        "projects/\(projectId)/issues/\(iid)/related_merge_requests",
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
        throw GitLabIssueFetchError.processError(errStr)
    }

    guard !outData.isEmpty else { return 0 }
    let trimmed = trimmingNonJSONPrefix(outData)
    let decoded = try JSONDecoder().decode([GLRelatedMRResponse].self, from: trimmed)
    return decoded.filter { $0.state == "opened" }.count
}

// MARK: - Project Labels

private struct GLLabelResponse: Decodable {
    let name: String?
    let color: String?
    let text_color: String?
}

/// Fetches the project's labels via `glab api --paginate projects/:id/labels`
/// so the side panel can render each label chip with its real colour.
/// Mirrors the `--paginate` concatenation strategy used by
/// `MRDiscussions.fetchMRDiscussions`: glab joins page arrays back-to-back
/// (`[...][...]`), so we try the single-array decode first and fall back to
/// per-array splitting only if that fails.
func fetchGitLabProjectLabels(
    projectId: Int,
    in directory: String,
    perPage: Int = 100
) async throws -> [GitLabLabel] {
    guard let glabPath = findGlabPath() else {
        throw GitLabIssueFetchError.glabNotFound
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: glabPath)
    process.arguments = [
        "api",
        "--paginate",
        "projects/\(projectId)/labels?per_page=\(perPage)",
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
        throw GitLabIssueFetchError.processError(errStr)
    }
    guard !outData.isEmpty else { return [] }

    let decoder = JSONDecoder()
    var decoded: [GLLabelResponse] = []
    if let single = try? decoder.decode([GLLabelResponse].self, from: outData) {
        decoded = single
    } else {
        for chunk in splitConcatenatedJSONArrays(outData) {
            if let page = try? decoder.decode([GLLabelResponse].self, from: chunk) {
                decoded.append(contentsOf: page)
            }
        }
    }

    return decoded.compactMap { raw in
        guard let name = raw.name, !name.isEmpty else { return nil }
        return GitLabLabel(
            name: name,
            color: raw.color ?? "",
            textColor: raw.text_color ?? ""
        )
    }
}

