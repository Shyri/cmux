import Foundation

// MARK: - Model

struct GitLabPipeline: Identifiable, Equatable, Sendable {
    let id: Int
    let iid: Int?
    let status: String
    let ref: String
    let sha: String
    let webURL: String
    let source: String?
    let createdAt: Date?
    let updatedAt: Date?

    var shortSHA: String {
        String(sha.prefix(8))
    }
}

// MARK: - JSON Decoding (glab ci list -F json)

private struct GLPipelineResponse: Decodable {
    let id: Int
    let iid: Int?
    let status: String?
    let ref: String?
    let sha: String?
    let web_url: String?
    let source: String?
    let created_at: String?
    let updated_at: String?

    func toModel() -> GitLabPipeline {
        GitLabPipeline(
            id: id,
            iid: iid,
            status: status ?? "",
            ref: ref ?? "",
            sha: sha ?? "",
            webURL: web_url ?? "",
            source: source,
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
        return fmt.date(from: str)
    }
}

// MARK: - Fetcher

enum GitLabPipelineFetchError: Error, Sendable {
    case glabNotFound
    case notGitLabRepo
    case processError(String)
    case parseError
}

func fetchGitLabPipelines(
    in directory: String,
    perPage: Int = 20
) async throws -> [GitLabPipeline] {
    let glabPath = findGlabExecutable()
    guard let glabPath else { throw GitLabPipelineFetchError.glabNotFound }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: glabPath)
    process.arguments = ["ci", "list", "-F", "json", "--per-page", "\(perPage)"]
    process.currentDirectoryURL = URL(fileURLWithPath: directory)

    var env = ProcessInfo.processInfo.environment
    env["NO_COLOR"] = "1"
    process.environment = env

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let outData = stdout.fileHandleForReading.readDataToEndOfFile()

    guard process.terminationStatus == 0 else {
        let errStr = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if errStr.contains("None of the git remotes") || errStr.contains("not a git repository") {
            throw GitLabPipelineFetchError.notGitLabRepo
        }
        throw GitLabPipelineFetchError.processError(errStr)
    }

    guard !outData.isEmpty else { return [] }

    let decoder = JSONDecoder()
    let responses = try decoder.decode([GLPipelineResponse].self, from: outData)
    return responses.map { $0.toModel() }
}

private func findGlabExecutable() -> String? {
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
