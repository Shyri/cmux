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

struct GitLabIssue: Identifiable, Equatable, Sendable {
    let id: Int
    let iid: Int
    let title: String
    let state: String
    let authorName: String
    let authorUsername: String
    let webURL: String
    let labels: [String]
    let milestone: GitLabMilestone?
    let assignees: [GitLabAssignee]
    let userNotesCount: Int
    let createdAt: Date?
    let updatedAt: Date?
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
            updatedAt: Self.parseDate(updated_at)
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

// MARK: - Fetcher

enum GitLabIssueFetchError: Error, Sendable {
    case glabNotFound
    case notGitLabRepo
    case processError(String)
    case parseError
}

func fetchGitLabIssues(
    in directory: String,
    perPage: Int = 30
) async throws -> [GitLabIssue] {
    let glabPath = findGlabPath()
    guard let glabPath else { throw GitLabIssueFetchError.glabNotFound }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: glabPath)
    process.arguments = ["issue", "list", "-O", "json", "--per-page", "\(perPage)"]
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

private func trimmingNonJSONPrefix(_ data: Data) -> Data {
    guard let firstBracket = data.firstIndex(where: { $0 == 0x5B /* [ */ || $0 == 0x7B /* { */ }) else {
        return data
    }
    return data.subdata(in: firstBracket..<data.endIndex)
}

private func findGlabPath() -> String? {
    let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    ]
    if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
        for dir in pathEnv.split(separator: ":") {
            let full = "\(dir)/glab"
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
    }
    for dir in searchPaths {
        let full = "\(dir)/glab"
        if FileManager.default.isExecutableFile(atPath: full) {
            return full
        }
    }
    return nil
}
