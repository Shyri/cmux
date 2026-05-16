import Foundation

/// Drains a process's stdout and stderr pipes concurrently to avoid deadlocks
/// when either stream fills the kernel pipe buffer (typically 16–64 KB on
/// macOS). Reading them sequentially can hang glab if it tries to flush the
/// unread stream while we block on the other.
func drainPipesInParallel(stdout: Pipe, stderr: Pipe) -> (Data, Data) {
    var outData = Data()
    var errData = Data()
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "gitlab.pipe.drain", attributes: .concurrent)

    group.enter()
    queue.async {
        outData = stdout.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }

    group.enter()
    queue.async {
        errData = stderr.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }

    group.wait()
    return (outData, errData)
}

/// Returns the normalized HTTPS web URL of the `origin` remote in `directory`,
/// or `nil` if it can't be determined. Handles SSH (`git@host:group/proj.git`)
/// and HTTPS (`https://host/group/proj.git`) remotes, stripping the trailing
/// `.git`.
func gitLabProjectWebURL(directory: String) async -> String? {
    await Task.detached(priority: .utility) { () -> String? in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "remote", "get-url", "origin"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              var raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        if raw.hasSuffix(".git") { raw.removeLast(4) }

        if raw.hasPrefix("git@") {
            if let colon = raw.firstIndex(of: ":") {
                let host = raw[raw.index(raw.startIndex, offsetBy: 4)..<colon]
                let path = raw[raw.index(after: colon)...]
                return "https://\(host)/\(path)"
            }
            return nil
        }
        if raw.hasPrefix("ssh://git@") {
            let rest = raw.dropFirst("ssh://git@".count)
            return "https://\(rest)"
        }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return raw
        }
        return nil
    }.value
}
