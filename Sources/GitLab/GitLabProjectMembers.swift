import Foundation

// MARK: - Model

/// A single GitLab user surfaced for the "change assignee" context menu — both
/// project members and the currently authenticated user use this shape.
struct GitLabProjectMember: Identifiable, Equatable, Hashable, Sendable {
    let id: Int
    let name: String
    let username: String
}

// MARK: - Errors

enum GitLabMembersFetchError: Error, Sendable {
    case glabNotFound
    case processError(String)
    case parseError
}

// MARK: - JSON

private struct GLMemberResponse: Decodable {
    let id: Int?
    let name: String?
    let username: String?
}

// MARK: - Project members

/// Returns the merged direct + inherited member list of a GitLab project by
/// hitting `projects/:id/members/all`. Mirrors the `--paginate` decoding the
/// other GitLab fetchers use so a project with hundreds of members still
/// surfaces in one call.
func fetchGitLabProjectMembers(
    projectId: Int,
    in directory: String,
    perPage: Int = 100
) async throws -> [GitLabProjectMember] {
    guard let glabPath = findGlabPath() else {
        throw GitLabMembersFetchError.glabNotFound
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: glabPath)
    process.arguments = [
        "api",
        "--paginate",
        "projects/\(projectId)/members/all?per_page=\(perPage)",
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
        throw GitLabMembersFetchError.processError(errStr)
    }
    guard !outData.isEmpty else { return [] }

    let decoder = JSONDecoder()
    var decoded: [GLMemberResponse] = []
    if let single = try? decoder.decode([GLMemberResponse].self, from: outData) {
        decoded = single
    } else {
        for chunk in splitConcatenatedJSONArrays(outData) {
            if let page = try? decoder.decode([GLMemberResponse].self, from: chunk) {
                decoded.append(contentsOf: page)
            }
        }
    }

    var seenIds = Set<Int>()
    var members: [GitLabProjectMember] = []
    for raw in decoded {
        guard let id = raw.id, id > 0, seenIds.insert(id).inserted else { continue }
        let username = raw.username ?? ""
        let name = raw.name ?? ""
        guard !username.isEmpty || !name.isEmpty else { continue }
        members.append(GitLabProjectMember(id: id, name: name, username: username))
    }
    return members.sorted { lhs, rhs in
        let l = (lhs.name.isEmpty ? lhs.username : lhs.name).lowercased()
        let r = (rhs.name.isEmpty ? rhs.username : rhs.name).lowercased()
        return l < r
    }
}

// MARK: - Current user

/// Returns the currently authenticated GitLab user via `glab api user`. Used to
/// power the "Assign to me" entry in the assignee context menu.
func fetchGitLabCurrentUser(in directory: String) async throws -> GitLabProjectMember {
    guard let glabPath = findGlabPath() else {
        throw GitLabMembersFetchError.glabNotFound
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: glabPath)
    process.arguments = ["api", "user"]
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
        throw GitLabMembersFetchError.processError(errStr)
    }

    let trimmed = trimmingNonJSONPrefix(outData)
    guard let raw = try? JSONDecoder().decode(GLMemberResponse.self, from: trimmed),
          let id = raw.id, id > 0
    else {
        throw GitLabMembersFetchError.parseError
    }
    return GitLabProjectMember(
        id: id,
        name: raw.name ?? "",
        username: raw.username ?? ""
    )
}
