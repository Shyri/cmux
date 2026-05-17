import Foundation

/// Replicates Claude Code's `statusLine` setting for the headless chat
/// panel. Claude Code interactive lets the user define a shell command
/// that produces a one-line status text (model name, cost, branch,
/// whatever) — see `~/.claude/settings.json` → `statusLine`. The
/// `claude -p` headless CLI does NOT execute it for us, so the panel
/// runs the same command itself with the same stdin JSON contract and
/// shows the stdout above the input.
enum StatusLineRunner {
    /// Parsed `statusLine` config from settings.json.
    struct Config: Equatable {
        let command: String
        /// Source path the config was read from — used in tooltips and
        /// for cache invalidation if the file changes.
        let sourcePath: String
    }

    /// Subset of the per-session info Claude Code passes to a status-
    /// line command via stdin. We populate the same fields wherever we
    /// can; missing values fall back to defaults the script can read.
    struct SessionInfo {
        let sessionId: String?
        let transcriptPath: String?
        let cwd: String
        let modelId: String?
        let version: String
    }

    /// Search order matches Claude Code's: project local → project
    /// shared → user home. First match with a non-empty `statusLine`
    /// command wins.
    static func loadConfig(cwd: String) -> Config? {
        let cwdURL = URL(fileURLWithPath: cwd, isDirectory: true)
        let candidates: [URL] = [
            cwdURL.appendingPathComponent(".claude").appendingPathComponent("settings.local.json"),
            cwdURL.appendingPathComponent(".claude").appendingPathComponent("settings.json"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude")
                .appendingPathComponent("settings.json"),
        ]
        for url in candidates {
            if let cfg = try? readConfig(from: url) {
                return cfg
            }
        }
        return nil
    }

    /// Run `config.command` through `/bin/sh -c …` with the JSON stdin
    /// payload Claude Code documents. Returns the trimmed stdout, or
    /// `nil` if the command fails or times out. Capped at 5 seconds —
    /// status lines are meant to be fast.
    static func run(
        config: Config,
        info: SessionInfo,
        userPATH: String?
    ) -> String? {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", config.command]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.currentDirectoryURL = URL(fileURLWithPath: info.cwd, isDirectory: true)

        var env = ProcessInfo.processInfo.environment
        if let userPATH, !userPATH.isEmpty { env["PATH"] = userPATH }
        process.environment = env

        let payload = makeStdinPayload(info: info)
        do {
            try process.run()
        } catch {
            return nil
        }
        // Pipe the JSON payload, then close stdin so the command knows
        // the input is complete.
        stdin.fileHandleForWriting.write(payload)
        try? stdin.fileHandleForWriting.close()

        // Bounded wait so a slow / hung script never freezes the panel.
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: outData, encoding: .utf8) else { return nil }
        // Keep ANSI/CSI/OSC escapes intact — the view layer parses
        // them into an AttributedString so colors, bold, italic and
        // underline render the way the user's status-line script
        // intended. Just trim trailing whitespace/newlines.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Private

    private static func readConfig(from url: URL) throws -> Config? {
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = json as? [String: Any],
              let statusLine = dict["statusLine"] as? [String: Any]
        else { return nil }
        // Type defaults to "command" — only that variant is supported
        // by Claude Code, but we still tolerate other future types by
        // returning nil rather than throwing.
        let type = (statusLine["type"] as? String) ?? "command"
        guard type == "command" else { return nil }
        guard let command = (statusLine["command"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty
        else { return nil }
        return Config(command: command, sourcePath: url.path)
    }

    private static func makeStdinPayload(info: SessionInfo) -> Data {
        var model: [String: Any] = [:]
        if let id = info.modelId {
            model["id"] = id
            model["display_name"] = id
        }
        let workspace: [String: Any] = [
            "current_dir": info.cwd,
            "project_dir": info.cwd,
        ]
        var payload: [String: Any] = [
            "hook_event_name": "Status",
            "cwd": info.cwd,
            "version": info.version,
            "model": model,
            "workspace": workspace,
            "output_style": ["name": "default"],
        ]
        if let sid = info.sessionId { payload["session_id"] = sid }
        if let tp = info.transcriptPath { payload["transcript_path"] = tp }
        return (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data()
    }

}
