import Foundation

// MARK: - Model

struct GitLabReleaseAsset: Equatable, Hashable, Sendable, Identifiable {
    var id: String { "\(name)|\(url)" }
    let name: String
    let url: String
    let linkType: String?  // "other", "runbook", "image", "package"
}

struct GitLabRelease: Identifiable, Equatable, Sendable {
    var id: String { tagName }
    let tagName: String
    let name: String
    let description: String
    let webURL: String
    let authorName: String
    let authorUsername: String
    let createdAt: Date?
    let releasedAt: Date?
    let upcomingRelease: Bool
    let assetLinks: [GitLabReleaseAsset]
    let sourceCount: Int
}

// MARK: - JSON Decoding (glab release list -F json)

private struct GLReleaseAuthor: Decodable {
    let name: String?
    let username: String?
}

private struct GLReleaseLink: Decodable {
    let name: String?
    let url: String?
    let direct_asset_url: String?
    let link_type: String?
}

private struct GLReleaseSource: Decodable {
    let format: String?
    let url: String?
}

private struct GLReleaseAssets: Decodable {
    let count: Int?
    let sources: [GLReleaseSource]?
    let links: [GLReleaseLink]?
}

private struct GLReleaseLinks: Decodable {
    let `self`: String?
}

private struct GLReleaseResponse: Decodable {
    let name: String?
    let tag_name: String?
    let description: String?
    let created_at: String?
    let released_at: String?
    let upcoming_release: Bool?
    let author: GLReleaseAuthor?
    let assets: GLReleaseAssets?
    let _links: GLReleaseLinks?

    func toModel() -> GitLabRelease {
        let assets = (self.assets?.links ?? []).compactMap { link -> GitLabReleaseAsset? in
            let name = link.name ?? ""
            let url = link.direct_asset_url ?? link.url ?? ""
            guard !url.isEmpty else { return nil }
            return GitLabReleaseAsset(
                name: name.isEmpty ? url : name,
                url: url,
                linkType: link.link_type
            )
        }
        let sourceCount = (self.assets?.sources ?? []).count
        return GitLabRelease(
            tagName: tag_name ?? "",
            name: (name?.isEmpty == false ? name! : (tag_name ?? "")),
            description: description ?? "",
            webURL: _links?.`self` ?? "",
            authorName: author?.name ?? "",
            authorUsername: author?.username ?? "",
            createdAt: Self.parseDate(created_at),
            releasedAt: Self.parseDate(released_at),
            upcomingRelease: upcoming_release ?? false,
            assetLinks: assets,
            sourceCount: sourceCount
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

enum GitLabReleaseFetchError: Error, Sendable {
    case glabNotFound
    case notGitLabRepo
    case processError(String)
    case parseError
}

func fetchGitLabReleases(
    in directory: String,
    perPage: Int = 20
) async throws -> [GitLabRelease] {
    let glabPath = findGlabPath()
    guard let glabPath else { throw GitLabReleaseFetchError.glabNotFound }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: glabPath)
    process.arguments = ["release", "list", "-F", "json", "--per-page", "\(perPage)"]
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
            throw GitLabReleaseFetchError.notGitLabRepo
        }
        throw GitLabReleaseFetchError.processError(errStr)
    }

    guard !outData.isEmpty else { return [] }

    let decoder = JSONDecoder()
    do {
        let responses = try decoder.decode([GLReleaseResponse].self, from: outData)
        return responses.map { $0.toModel() }
    } catch {
        let preview = String(data: outData.prefix(300), encoding: .utf8) ?? "<non-utf8>"
        throw GitLabReleaseFetchError.processError("Decode error: \(error.localizedDescription)\nOutput: \(preview)")
    }
}

