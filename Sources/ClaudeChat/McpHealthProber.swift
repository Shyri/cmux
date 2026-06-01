import Foundation

/// Stateless helper that spawns `claude mcp list` / `claude mcp get
/// <name>` to ask Claude Code about MCP connectivity *right now*,
/// without touching the chat's persistent `claude -p` process. The
/// chat panel uses this to refresh the MCP manager popover badges
/// when the user opens it or hits Refresh — `system/init` only fires
/// when the long-running process spawns, so without an external probe
/// the badges would be frozen.
enum McpHealthProber {
    /// Run `claude mcp list` in `cwd` and parse the output into one
    /// `McpServerInitStatus` per server. Returns an empty list if the
    /// command is missing or the output cannot be understood.
    static func probeAll(claudePath: String, cwd: String) async -> [McpServerInitStatus] {
        let stdout = await runCapture(
            claudePath: claudePath,
            args: ["mcp", "list"],
            cwd: cwd
        )
        return parseList(stdout)
    }

    /// Run `claude mcp get <name>` in `cwd` and parse the result for
    /// the matching server. Returns nil if `claude` returned no output
    /// or the line could not be matched.
    static func probeOne(name: String, claudePath: String, cwd: String) async -> McpServerInitStatus? {
        let stdout = await runCapture(
            claudePath: claudePath,
            args: ["mcp", "get", name],
            cwd: cwd
        )
        // `mcp get` includes a health-check line in the same shape as
        // `mcp list`, so we reuse the list parser and look for our
        // entry. If the line is missing, fall back to scraping a
        // top-level "Status:" / "Health:" key out of the body.
        if let match = parseList(stdout).first(where: { $0.name == name }) {
            return match
        }
        return parseGet(stdout, name: name)
    }

    // MARK: - Process plumbing

    private static func runCapture(claudePath: String, args: [String], cwd: String) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard FileManager.default.isExecutableFile(atPath: claudePath) else {
                    continuation.resume(returning: "")
                    return
                }
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                // Wrap `claude mcp list`/`get` in the same login shell as
                // the chat's persistent `claude -p` process. claude
                // health-checks each MCP server by spawning its
                // `command` (npx/uvx/pipx/bun/glab/…); without the
                // wrapper those subprocesses see the GUI app's stripped
                // env and fail, so the popover would mark servers as
                // failed even when they're connected in the running
                // chat session. Both paths must observe the same env to
                // avoid flapping/contradictory badges.
                let (executableURL, processArguments) = ClaudeLoginShellWrapper.wrap(
                    claudePath: claudePath,
                    arguments: args
                )
                process.executableURL = executableURL
                process.arguments = processArguments
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "")
                    return
                }
                process.waitUntilExit()
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }

    // MARK: - Output parsing

    /// Each non-empty line of `claude mcp list` matches:
    /// `<name>: <command-or-url> - <symbol> <status-text>`
    /// We split on " - " and look at the suffix to decide the status.
    static func parseList(_ stdout: String) -> [McpServerInitStatus] {
        var out: [McpServerInitStatus] = []
        for line in stdout.components(separatedBy: "\n") {
            let stripped = stripAnsi(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { continue }
            guard let entry = parseLine(stripped) else { continue }
            out.append(entry)
        }
        return out
    }

    private static func parseGet(_ stdout: String, name: String) -> McpServerInitStatus? {
        // `mcp get` typically prints the same single-line summary as
        // `mcp list`; if that line exists it's already handled by
        // parseList. As a fallback we look for an explicit
        // `Status: <value>` line and synthesise an entry.
        for line in stdout.components(separatedBy: "\n") {
            let stripped = stripAnsi(line).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = stripped.lowercased()
            if lower.hasPrefix("status:") || lower.hasPrefix("health:") {
                let value = stripped.components(separatedBy: ":").dropFirst()
                    .joined(separator: ":")
                    .trimmingCharacters(in: .whitespaces)
                return classify(name: name, statusLine: value)
            }
        }
        return nil
    }

    private static func parseLine(_ line: String) -> McpServerInitStatus? {
        // Expected: "name: target - ✓ Connected" / "name: target - ✗ Failed: reason"
        // Some builds use "  ✓" / "  ✗" / "  !" prefixes without the
        // " - " separator; cope with both.
        let separators = [" - ", " — "]
        for sep in separators {
            if let range = line.range(of: sep) {
                let head = line[..<range.lowerBound]
                let tail = line[range.upperBound...]
                guard let colon = head.firstIndex(of: ":") else { continue }
                let name = String(head[..<colon]).trimmingCharacters(in: .whitespaces)
                if name.isEmpty { continue }
                return classify(name: name, statusLine: String(tail))
            }
        }
        // Skip headers like "Checking MCP server health…".
        return nil
    }

    private static func classify(name: String, statusLine: String) -> McpServerInitStatus {
        let lower = statusLine.lowercased()
        if lower.contains("connected") {
            return .init(name: name, status: "connected", error: nil)
        }
        if lower.contains("needs authentication") || lower.contains("needs auth") {
            return .init(name: name, status: "needs-auth", error: nil)
        }
        if lower.contains("failed") || lower.contains("error") {
            // The portion after "Failed:" / "Error:" is the reason
            // (best-effort: include the whole tail when no colon is
            // present so the user at least sees something).
            var reason = statusLine
            if let idx = statusLine.firstIndex(of: ":") {
                reason = String(statusLine[statusLine.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            }
            return .init(name: name, status: "failed", error: reason.isEmpty ? nil : reason)
        }
        return .init(name: name, status: "unknown", error: statusLine)
    }

    /// Strip the most common ANSI colour escape sequences so the
    /// parser sees plain text. Claude's CLI uses bold/colour for the
    /// status symbols, which would otherwise sneak through.
    private static func stripAnsi(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        // ESC[<...>m and ESC[<...>K — the only sequences we have seen
        // in `mcp list` output. Keep the regex tight to avoid eating
        // legitimate characters.
        do {
            let regex = try NSRegularExpression(pattern: "\u{001B}\\[[0-9;]*[mK]")
            let range = NSRange(s.startIndex..., in: s)
            return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        } catch {
            return s
        }
    }
}
