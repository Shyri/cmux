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

// MARK: - Job model

struct GitLabJob: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let status: String
    let stage: String
    let hasArtifacts: Bool
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
    let glabPath = findGlabPath()
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
    let (outData, errData) = drainPipesInParallel(stdout: stdout, stderr: stderr)
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let errStr = String(data: errData, encoding: .utf8) ?? ""
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

// MARK: - Jobs Fetch

private struct GLJobArtifact: Decodable {
    let file_type: String?
    let filename: String?
    let size: Int?
}

private struct GLJobResponse: Decodable {
    let id: Int
    let name: String?
    let status: String?
    let stage: String?
    let artifacts_file: GLJobArtifact?
    let artifacts: [GLJobArtifact]?
}

private struct GLPipelineDetail: Decodable {
    let jobs: [GLJobResponse]?
}

func fetchJobsForPipeline(
    pipelineID: Int,
    in directory: String
) async throws -> [GitLabJob] {
    let glabPath = findGlabPath()
    guard let glabPath else { throw GitLabPipelineFetchError.glabNotFound }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: glabPath)
    process.arguments = [
        "ci", "get",
        "-p", "\(pipelineID)",
        "-F", "json",
        "--with-job-details",
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
        throw GitLabPipelineFetchError.processError(errStr)
    }

    guard !outData.isEmpty else { return [] }

    let decoder = JSONDecoder()
    let detail = try decoder.decode(GLPipelineDetail.self, from: outData)
    return (detail.jobs ?? []).map { j in
        let hasFile = j.artifacts_file?.filename != nil
        let hasArts = (j.artifacts ?? []).contains { $0.filename != nil }
        return GitLabJob(
            id: j.id,
            name: j.name ?? "",
            status: j.status ?? "",
            stage: j.stage ?? "",
            hasArtifacts: hasFile || hasArts
        )
    }
}

// MARK: - Artifact Download

@MainActor
func downloadArtifacts(
    ref: String,
    jobName: String,
    in directory: String
) async throws -> URL {
    let glabPath = findGlabPath()
    guard let glabPath else { throw GitLabPipelineFetchError.glabNotFound }

    let downloadsBase = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    let sanitizedJob = jobName.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    let sanitizedRef = ref.replacingOccurrences(of: "/", with: "_")
    let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
    let target = downloadsBase
        .appendingPathComponent("cmux-artifacts", isDirectory: true)
        .appendingPathComponent("\(sanitizedRef)-\(sanitizedJob)-\(stamp)", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: glabPath)
    process.arguments = [
        "job", "artifact", ref, jobName,
        "--path", target.path + "/",
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: directory)

    var env = ProcessInfo.processInfo.environment
    env["NO_COLOR"] = "1"
    process.environment = env

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        process.terminationHandler = { _ in
            if process.terminationStatus == 0 {
                cont.resume()
            } else {
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(throwing: GitLabPipelineFetchError.processError(err))
            }
        }
        do {
            try process.run()
        } catch {
            cont.resume(throwing: error)
        }
    }

    return target
}

