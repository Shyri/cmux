import Foundation

// MARK: - Model

struct GitLabReviewer: Equatable, Hashable, Sendable {
    let name: String
    let username: String
}

struct GitLabMergeRequest: Identifiable, Equatable, Sendable {
    let id: Int
    let iid: Int
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
    let userNotesCount: Int
}

// MARK: - JSON Decoding (glab mr list -F json)

private struct GLMRAuthor: Decodable {
    let name: String?
    let username: String?
}

private struct GLMRResponse: Decodable {
    let id: Int
    let iid: Int
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
    let user_notes_count: Int?

    func toModel() -> GitLabMergeRequest {
        GitLabMergeRequest(
            id: id,
            iid: iid,
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
            userNotesCount: user_notes_count ?? 0
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
    let glabPath = findExecutable("glab")
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
    guard let glabPath = findExecutable("glab") else {
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

/// Search common paths for an executable.
private func findExecutable(_ name: String) -> String? {
    let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    ]
    // Check PATH first
    if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
        for dir in pathEnv.split(separator: ":") {
            let full = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
    }
    // Fallback to known paths
    for dir in searchPaths {
        let full = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: full) {
            return full
        }
    }
    return nil
}
