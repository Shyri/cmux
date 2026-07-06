import Foundation

/// Locates the `glab` executable, searching `$PATH` first and falling back to
/// the Homebrew/system prefixes. Returns `nil` if the binary isn't installed.
func findGlabPath() -> String? {
    let fallbackDirs = [
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
    for dir in fallbackDirs {
        let full = "\(dir)/glab"
        if FileManager.default.isExecutableFile(atPath: full) {
            return full
        }
    }
    return nil
}

/// Trims any bytes before the first `[` or `{` in `data`. Some `glab` versions
/// emit warnings to stdout before the JSON payload; this peels them off so
/// JSONDecoder can succeed.
func trimmingNonJSONPrefix(_ data: Data) -> Data {
    guard let firstBracket = data.firstIndex(where: {
        $0 == 0x5B /* [ */ || $0 == 0x7B /* { */
    }) else {
        return data
    }
    return data.subdata(in: firstBracket..<data.endIndex)
}

/// Splits the bytes returned by `glab api --paginate` into individual JSON
/// arrays. `glab` concatenates page arrays back-to-back (`[...][...]`); this
/// tracks bracket depth (respecting string escapes) so each page can be
/// decoded independently.
func splitConcatenatedJSONArrays(_ data: Data) -> [Data] {
    var results: [Data] = []
    var depth = 0
    var start: Int? = nil
    var inString = false
    var escape = false
    let bytes = [UInt8](data)
    for (i, b) in bytes.enumerated() {
        if inString {
            if escape { escape = false; continue }
            if b == 0x5C /* \ */ { escape = true; continue }
            if b == 0x22 /* " */ { inString = false }
            continue
        }
        if b == 0x22 /* " */ { inString = true; continue }
        if b == 0x5B /* [ */ {
            if depth == 0 { start = i }
            depth += 1
        } else if b == 0x5D /* ] */ {
            depth -= 1
            if depth == 0, let s = start {
                results.append(data.subdata(in: s ..< (i + 1)))
                start = nil
            }
        }
    }
    return results
}

/// Drains a process's stdout and stderr pipes concurrently to avoid deadlocks
/// when either stream fills the kernel pipe buffer (typically 16–64 KB on
/// macOS). Reading them sequentially can hang glab if it tries to flush the
/// unread stream while we block on the other.
///
/// Hard `timeout` ceiling: `glab` (and `git`) routinely spawn helper
/// subprocesses — credential/keyring helpers, OAuth browser openers — that
/// inherit fd 1/2. If such a helper outlives the main process, the pipe's
/// write end is never fully closed, so a plain `readDataToEndOfFile()` never
/// sees EOF and blocks its thread *forever*. Because these drains run inside
/// Swift Concurrency tasks (e.g. the MR-approvals fan-out), a handful of such
/// permanent blocks saturate the fixed-width cooperative thread pool and wedge
/// every other `async` task in the app — including the Claude Chat panel
/// startup, which then spins on "Thinking…" indefinitely (cooperative-pool
/// starvation). The watchdog force-closes the read handles after `timeout`
/// so the reads return whatever they have and the thread is freed.
///
/// Reads use the throwing `read(upToCount:)` in a loop (not the legacy
/// `readDataToEndOfFile()`, which raises an *ObjC* exception on a mid-read
/// close that Swift cannot catch → crash). A close from the watchdog surfaces
/// as a Swift error, which just ends the loop.
func drainPipesInParallel(
    stdout: Pipe,
    stderr: Pipe,
    timeout: TimeInterval = 30
) -> (Data, Data) {
    let outHandle = stdout.fileHandleForReading
    let errHandle = stderr.fileHandleForReading
    var outData = Data()
    var errData = Data()
    let lock = NSLock()
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "gitlab.pipe.drain", attributes: .concurrent)

    func drain(_ handle: FileHandle, append: @escaping (Data) -> Void) {
        group.enter()
        queue.async {
            while true {
                let chunk: Data?
                do {
                    chunk = try handle.read(upToCount: 64 * 1024)
                } catch {
                    // Handle closed by the watchdog (or a genuine read
                    // error) — stop draining this stream.
                    break
                }
                guard let chunk, !chunk.isEmpty else { break }  // nil/empty == EOF
                append(chunk)
            }
            group.leave()
        }
    }

    drain(outHandle) { chunk in lock.lock(); outData.append(chunk); lock.unlock() }
    drain(errHandle) { chunk in lock.lock(); errData.append(chunk); lock.unlock() }

    if group.wait(timeout: .now() + timeout) == .timedOut {
        // Break a leaked-write-end deadlock: closing the read ends makes the
        // in-flight `read(upToCount:)` calls throw, ending both drain loops.
        try? outHandle.close()
        try? errHandle.close()
        group.wait()
    }

    lock.lock()
    defer { lock.unlock() }
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
