import Foundation

/// Spawns `claude -p` per turn and streams `stream-json` events back to the
/// caller. Phase 2 of the MVP uses one-shot invocation with `--resume` for
/// follow-up turns; phase 3 will inject an MCP `--permission-prompt-tool`
/// for inline allow/deny.
final class ClaudeChatRunner {
    enum RunnerError: Error, LocalizedError {
        case claudeNotFound
        case spawnFailed(String)
        case nonZeroExit(code: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .claudeNotFound:
                return String(
                    localized: "claudeChat.error.claudeNotFound",
                    defaultValue:
                        "Claude CLI not found. Install with `npm install -g @anthropic-ai/claude-code` or set the path in Settings → Claude Code."
                )
            case .spawnFailed(let reason):
                return String(
                    localized: "claudeChat.error.spawnFailed",
                    defaultValue: "Failed to launch claude: \(reason)"
                )
            case .nonZeroExit(let code, let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return String(
                        localized: "claudeChat.error.nonZeroExit",
                        defaultValue: "claude exited with code \(code)"
                    )
                }
                return "claude exited with code \(code):\n\(trimmed)"
            }
        }
    }

    /// Callbacks are invoked on the main thread/queue for direct binding to
    /// `@MainActor` UI state.
    typealias EventHandler = (ClaudeStreamEvent) -> Void
    typealias CompletionHandler = (Result<Void, Error>) -> Void

    private var process: Process?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var isCancelled = false
    private let processQueue = DispatchQueue(label: "com.cmux.claudechat.runner", qos: .userInitiated)

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    func start(
        userMessage: String,
        cwd: String,
        sessionId: String?,
        permissionMode: String,
        mcpConfigPath: String? = nil,
        permissionPromptTool: String? = nil,
        appendSystemPrompt: String? = nil,
        onEvent: @escaping EventHandler,
        onComplete: @escaping CompletionHandler
    ) {
        processQueue.async { [weak self] in
            guard let self else { return }
            do {
                let claudePath = try self.resolveClaudePath()
                try self.launch(
                    claudePath: claudePath,
                    userMessage: userMessage,
                    cwd: cwd,
                    sessionId: sessionId,
                    permissionMode: permissionMode,
                    mcpConfigPath: mcpConfigPath,
                    permissionPromptTool: permissionPromptTool,
                    appendSystemPrompt: appendSystemPrompt,
                    onEvent: onEvent,
                    onComplete: onComplete
                )
            } catch {
                DispatchQueue.main.async {
                    onComplete(.failure(error))
                }
            }
        }
    }

    /// SIGINT the in-flight subprocess. claude handles it cleanly and exits.
    func cancel() {
        processQueue.async { [weak self] in
            guard let self else { return }
            self.isCancelled = true
            if let process = self.process, process.isRunning {
                process.interrupt()
            }
        }
    }

    // MARK: - Private

    private func launch(
        claudePath: String,
        userMessage: String,
        cwd: String,
        sessionId: String?,
        permissionMode: String,
        mcpConfigPath: String?,
        permissionPromptTool: String?,
        appendSystemPrompt: String?,
        onEvent: @escaping EventHandler,
        onComplete: @escaping CompletionHandler
    ) throws {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: claudePath)
        var arguments: [String] = [
            "-p", userMessage,
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", permissionMode
        ]
        if let mcpConfigPath, !mcpConfigPath.isEmpty {
            arguments += ["--mcp-config", mcpConfigPath]
            // Disable Claude Code's built-in `AskUserQuestion` whenever our
            // MCP server is up. The built-in self-denies in `-p` (headless)
            // mode, which surfaces to the user as a "cancelled" question.
            // We always want claude to reach for `mcp__cmux__ask_user_question`
            // instead — irrespective of the permission mode.
            arguments += ["--disallowed-tools", "AskUserQuestion"]
        }
        if let permissionPromptTool, !permissionPromptTool.isEmpty {
            arguments += ["--permission-prompt-tool", permissionPromptTool]
        }
        if let appendSystemPrompt, !appendSystemPrompt.isEmpty {
            arguments += ["--append-system-prompt", appendSystemPrompt]
        }
        if let sessionId, !sessionId.isEmpty {
            arguments += ["--resume", sessionId]
        }
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        // Ensure the spawned claude inherits a sane PATH even when launched
        // from the app sandbox context. Read the user's interactive PATH via
        // the resolver-cached value if available; otherwise fall back to
        // the parent process environment.
        var environment = ProcessInfo.processInfo.environment
        if let userPath = ClaudeChatRunner.cachedUserPath {
            environment["PATH"] = userPath
        }
        process.environment = environment

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.handleStdout(chunk: chunk, onEvent: onEvent)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.processQueue.async {
                self?.stderrBuffer.append(chunk)
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.processQueue.async {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                self.flushRemainingStdout(onEvent: onEvent)

                let exitCode = proc.terminationStatus
                let cancelled = self.isCancelled
                self.process = nil
                self.isCancelled = false
                self.stdoutBuffer.removeAll(keepingCapacity: false)
                let stderrText = String(data: self.stderrBuffer, encoding: .utf8) ?? ""
                self.stderrBuffer.removeAll(keepingCapacity: false)

                DispatchQueue.main.async {
                    if cancelled {
                        onComplete(.success(()))
                    } else if exitCode != 0 {
                        onComplete(.failure(RunnerError.nonZeroExit(code: exitCode, stderr: stderrText)))
                    } else {
                        onComplete(.success(()))
                    }
                }
            }
        }

        // Debug: write the full claude invocation to /tmp so the user can
        // inspect what flags were actually passed. Helpful when tool-use
        // routing misbehaves (e.g. claude reaches for a built-in we tried
        // to disallow).
        ChatRunnerDebugLog.shared.appendInvocation(
            executable: claudePath,
            arguments: arguments,
            cwd: cwd
        )

        do {
            try process.run()
        } catch {
            throw RunnerError.spawnFailed(error.localizedDescription)
        }
        self.process = process
    }

    /// Append a chunk to the line buffer and emit one event per complete
    /// newline-terminated NDJSON line.
    private func handleStdout(chunk: Data, onEvent: @escaping EventHandler) {
        processQueue.async { [weak self] in
            guard let self else { return }
            self.stdoutBuffer.append(chunk)
            self.drainBufferedLines(onEvent: onEvent)
        }
    }

    private func drainBufferedLines(onEvent: @escaping EventHandler) {
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newlineIndex)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            dispatchLine(line, onEvent: onEvent)
        }
    }

    private func flushRemainingStdout(onEvent: @escaping EventHandler) {
        // claude always terminates lines with \n, but if the process is
        // killed mid-line we still want to attempt a parse so partial errors
        // surface to the user.
        guard !stdoutBuffer.isEmpty else { return }
        if let line = String(data: stdoutBuffer, encoding: .utf8) {
            dispatchLine(line, onEvent: onEvent)
        }
        stdoutBuffer.removeAll(keepingCapacity: false)
    }

    private func dispatchLine(_ line: String, onEvent: @escaping EventHandler) {
        ChatRunnerDebugLog.shared.appendStdoutLine(line)
        do {
            guard let event = try ClaudeStreamEvent.parse(line: line) else { return }
            DispatchQueue.main.async {
                onEvent(event)
            }
        } catch {
            #if DEBUG
            NSLog("ClaudeChatRunner: failed to parse line: \(error.localizedDescription) line=\(line.prefix(200))")
            #endif
        }
    }

    // MARK: - Binary resolution

    private static var cachedClaudePath: String?
    private static var cachedUserPath: String?
    private static let cacheLock = NSLock()

    private func resolveClaudePath() throws -> String {
        if let custom = UserDefaults.standard.string(forKey: ClaudeCodeIntegrationSettings.customClaudePathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty,
           FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }

        Self.cacheLock.lock()
        let cached = Self.cachedClaudePath
        Self.cacheLock.unlock()
        if let cached, FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }

        // Fall back to running `command -v claude` in an interactive zsh so
        // the user's PATH (homebrew, asdf, nvm, fnm, …) is respected. We
        // also stash the resolved PATH so the spawned `claude` inherits it.
        let probe = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-l", "-c", "printf '%s\\n' \"${PATH}\"; command -v claude || true"]
        probe.standardOutput = stdoutPipe
        probe.standardError = stderrPipe

        do {
            try probe.run()
        } catch {
            throw RunnerError.spawnFailed("zsh probe: \(error.localizedDescription)")
        }
        probe.waitUntilExit()

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let lines = stdout.split(separator: "\n").map(String.init)
        guard lines.count >= 1 else {
            throw RunnerError.claudeNotFound
        }
        let userPath = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let foundPath = (lines.dropFirst().first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        Self.cacheLock.lock()
        if !userPath.isEmpty {
            Self.cachedUserPath = userPath
        }
        if !foundPath.isEmpty {
            Self.cachedClaudePath = foundPath
        }
        Self.cacheLock.unlock()

        guard !foundPath.isEmpty,
              FileManager.default.isExecutableFile(atPath: foundPath) else {
            throw RunnerError.claudeNotFound
        }
        return foundPath
    }
}
