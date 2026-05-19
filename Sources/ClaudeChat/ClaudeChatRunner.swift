import Foundation

/// Keeps a single `claude` subprocess alive per chat panel and streams its
/// stream-json output back to the caller. Mensajes nuevos se entregan por
/// stdin como NDJSON, así que el proceso no se relanza por turno: una sola
/// sesión persistente reusa la conexión al CLI, sus servidores MCP y su
/// contexto en memoria entre prompts. Esto es el mismo binario `claude` que
/// la app instalada del usuario — solo cambia `--input-format` para que el
/// CLI consuma mensajes desde stdin en vez de tomar el prompt como
/// argumento.
final class ClaudeChatRunner {
    enum RunnerError: Error, LocalizedError {
        case claudeNotFound
        case spawnFailed(String)
        case notRunning
        case stdinWriteFailed(String)
        case unexpectedExit(code: Int32, stderr: String)

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
            case .notRunning:
                return String(
                    localized: "claudeChat.error.notRunning",
                    defaultValue: "claude is not running. The next message will start a fresh session."
                )
            case .stdinWriteFailed(let reason):
                return String(
                    localized: "claudeChat.error.stdinWriteFailed",
                    defaultValue: "Failed to send message to claude: \(reason)"
                )
            case .unexpectedExit(let code, let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return String(
                        localized: "claudeChat.error.unexpectedExit",
                        defaultValue: "claude exited unexpectedly with code \(code)"
                    )
                }
                return "claude exited unexpectedly with code \(code):\n\(trimmed)"
            }
        }
    }

    /// Callbacks are invoked on the main thread/queue for direct binding to
    /// `@MainActor` UI state.
    typealias EventHandler = (ClaudeStreamEvent) -> Void
    /// Fired when the underlying `claude` process exits (either because we
    /// asked it to via `terminate()`, or unexpectedly because of a crash or
    /// because SIGINT escalated to an exit). `success` means the process
    /// went away cleanly; `failure` carries diagnostic detail.
    typealias ExitHandler = (Result<Void, Error>) -> Void

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    /// True between an explicit `terminate()` and the `terminationHandler`
    /// firing, so we can distinguish a user-requested shutdown from a crash.
    private var isTerminatingExplicitly = false
    private let processQueue = DispatchQueue(label: "com.cmux.claudechat.runner", qos: .userInitiated)

    /// Callbacks for the currently-running process. Replaced on each
    /// `ensureStarted` so the panel that holds the runner always wires up
    /// fresh weak-self captures.
    private var onEvent: EventHandler?
    private var onExit: ExitHandler?

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    /// Idempotent. If `claude` is already alive, this just refreshes the
    /// active callbacks; the running process keeps its in-memory session
    /// and MCP connections. If it's not running, spawn it now with the
    /// given options and wait for the first byte (which means the binary
    /// resolved and `Process.run()` succeeded).
    ///
    /// Note: `mcpConfigPath`, `permissionMode`, `appendSystemPrompt`, and
    /// `sessionId` are baked into the launch arguments — changing any of
    /// them mid-session requires a `terminate()` + next `ensureStarted`.
    func ensureStarted(
        cwd: String,
        sessionId: String?,
        permissionMode: String,
        mcpConfigPath: String?,
        permissionPromptTool: String?,
        appendSystemPrompt: String?,
        onEvent: @escaping EventHandler,
        onExit: @escaping ExitHandler
    ) {
        processQueue.async { [weak self] in
            guard let self else { return }
            // Always refresh callbacks so panel-side weak-self captures
            // point at the *current* view model.
            self.onEvent = onEvent
            self.onExit = onExit
            if let existing = self.process, existing.isRunning {
                return
            }
            do {
                let claudePath = try self.resolveClaudePath()
                try self.launch(
                    claudePath: claudePath,
                    cwd: cwd,
                    sessionId: sessionId,
                    permissionMode: permissionMode,
                    mcpConfigPath: mcpConfigPath,
                    permissionPromptTool: permissionPromptTool,
                    appendSystemPrompt: appendSystemPrompt
                )
            } catch {
                DispatchQueue.main.async {
                    onExit(.failure(error))
                }
            }
        }
    }

    /// Send a user-side turn to the running `claude` process. The CLI
    /// expects one NDJSON object per line on stdin in streaming-input
    /// mode, mirroring the `user` event shape from `--output-format
    /// stream-json`:
    ///
    /// ```json
    /// {"type":"user","message":{"role":"user","content":"hola"},"parent_tool_use_id":null}
    /// ```
    ///
    /// If the process is not alive (crashed, terminated, or never
    /// started), the call routes a failure through the current `onExit`
    /// handler so the panel can show an error and respawn next time.
    func sendUserTurn(_ text: String) {
        processQueue.async { [weak self] in
            guard let self else { return }
            guard let stdin = self.stdinHandle,
                  let process = self.process, process.isRunning else {
                DispatchQueue.main.async {
                    self.onExit?(.failure(RunnerError.notRunning))
                }
                return
            }
            let payload: [String: Any] = [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": text
                ],
                "parent_tool_use_id": NSNull()
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                DispatchQueue.main.async {
                    self.onExit?(.failure(RunnerError.stdinWriteFailed("failed to encode user turn")))
                }
                return
            }
            var line = data
            line.append(0x0A)  // '\n'
            ChatRunnerDebugLog.shared.appendStdoutLine(
                "→ stdin user turn (bytes=\(line.count))"
            )
            do {
                try stdin.write(contentsOf: line)
            } catch {
                DispatchQueue.main.async {
                    self.onExit?(.failure(RunnerError.stdinWriteFailed(error.localizedDescription)))
                }
            }
        }
    }

    /// Interrupt the in-flight turn (SIGINT). The process may or may not
    /// survive the signal depending on its build; either way the next
    /// `ensureStarted` respawns automatically. The session id we passed
    /// at launch (`--resume <id>`) means the new process picks up where
    /// the old one left off.
    func cancel() {
        processQueue.async { [weak self] in
            guard let self else { return }
            if let process = self.process, process.isRunning {
                process.interrupt()
            }
        }
    }

    /// Safety net: if the panel that owned this runner was released
    /// without going through `terminate()` (e.g. app quit shortcut,
    /// SwiftUI dropping the view tree on a workspace switch we missed,
    /// or a crash up the stack), still don't let the spawned `claude`
    /// outlive us. We can't dispatch async work from `deinit`, so we
    /// operate directly on the process handles. `Process.terminate()`
    /// just signals SIGTERM — the kernel reaps the subprocess. All
    /// previously-installed handlers capture `weak self`, so they
    /// become no-ops once we are gone.
    deinit {
        try? stdinHandle?.close()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    /// Terminate the process cleanly: close stdin so `claude` exits its
    /// stream-json loop, give it a beat, then SIGTERM if it's still
    /// around. Use this on panel close or `clearTranscript()`.
    func terminate() {
        processQueue.async { [weak self] in
            guard let self else { return }
            guard let process = self.process, process.isRunning else {
                self.process = nil
                self.stdinHandle = nil
                return
            }
            self.isTerminatingExplicitly = true
            try? self.stdinHandle?.close()
            self.stdinHandle = nil
            // Give the CLI a short window to flush; if it's still
            // alive we escalate to SIGTERM.
            self.processQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if let proc = self.process, proc.isRunning {
                    proc.terminate()
                }
            }
        }
    }

    // MARK: - Private

    private func launch(
        claudePath: String,
        cwd: String,
        sessionId: String?,
        permissionMode: String,
        mcpConfigPath: String?,
        permissionPromptTool: String?,
        appendSystemPrompt: String?
    ) throws {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: claudePath)
        var arguments: [String] = [
            "-p",
            "--input-format", "stream-json",
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
        process.standardInput = stdinPipe

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
            self?.handleStdout(chunk: chunk)
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
                self.flushRemainingStdout()

                let exitCode = proc.terminationStatus
                let wasExplicit = self.isTerminatingExplicitly
                self.process = nil
                self.stdinHandle = nil
                self.isTerminatingExplicitly = false
                self.stdoutBuffer.removeAll(keepingCapacity: false)
                let stderrText = String(data: self.stderrBuffer, encoding: .utf8) ?? ""
                self.stderrBuffer.removeAll(keepingCapacity: false)

                let exitCallback = self.onExit
                DispatchQueue.main.async {
                    if wasExplicit || exitCode == 0 {
                        exitCallback?(.success(()))
                    } else {
                        exitCallback?(.failure(
                            RunnerError.unexpectedExit(code: exitCode, stderr: stderrText)
                        ))
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
        self.stdinHandle = stdinPipe.fileHandleForWriting
    }

    /// Append a chunk to the line buffer and emit one event per complete
    /// newline-terminated NDJSON line.
    private func handleStdout(chunk: Data) {
        processQueue.async { [weak self] in
            guard let self else { return }
            self.stdoutBuffer.append(chunk)
            self.drainBufferedLines()
        }
    }

    private func drainBufferedLines() {
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newlineIndex)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            dispatchLine(line)
        }
    }

    private func flushRemainingStdout() {
        // claude always terminates lines with \n, but if the process is
        // killed mid-line we still want to attempt a parse so partial errors
        // surface to the user.
        guard !stdoutBuffer.isEmpty else { return }
        if let line = String(data: stdoutBuffer, encoding: .utf8) {
            dispatchLine(line)
        }
        stdoutBuffer.removeAll(keepingCapacity: false)
    }

    private func dispatchLine(_ line: String) {
        ChatRunnerDebugLog.shared.appendStdoutLine(line)
        do {
            guard let event = try ClaudeStreamEvent.parse(line: line) else { return }
            let callback = self.onEvent
            DispatchQueue.main.async {
                callback?(event)
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

    /// Expose the resolved binary path so the chat panel can spawn
    /// auxiliary `claude mcp list` / `claude mcp get` probes without
    /// re-implementing the multi-shell PATH dance.
    func resolveClaudeBinaryPath() throws -> String {
        try resolveClaudePath()
    }

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

        // Probe a few shells in turn to handle the typical install
        // scenarios:
        //   1. Login zsh — the conventional PATH; works for `npm
        //      install -g`, brew, system installs.
        //   2. Interactive zsh — needed when the user keeps `claude`
        //      under `~/.local/bin` or similar via .zshrc, which a
        //      login shell doesn't always source.
        //   3. Login bash — fallback for users who haven't migrated
        //      to zsh yet.
        // We accept the first probe that returns an executable path
        // OUTSIDE another `cmux.app` bundle (a sibling install often
        // ships its own `claude` in Resources/bin which is not what the
        // user means when they say "I have claude installed").
        let attempts: [(shell: String, args: [String])] = [
            ("/bin/zsh", ["-l", "-c", "printf '%s\\n' \"${PATH}\"; command -v claude || true"]),
            ("/bin/zsh", ["-i", "-c", "printf '%s\\n' \"${PATH}\"; command -v claude || true"]),
            ("/bin/bash", ["-l", "-c", "printf '%s\\n' \"${PATH}\"; command -v claude || true"]),
        ]

        var lastUserPath = ""
        for attempt in attempts {
            let (foundPath, userPath) = try probeForClaude(shell: attempt.shell, arguments: attempt.args)
            if !userPath.isEmpty { lastUserPath = userPath }
            if !foundPath.isEmpty,
               !pathLivesInsideAnotherCmuxBundle(foundPath),
               FileManager.default.isExecutableFile(atPath: foundPath) {
                Self.cacheLock.lock()
                if !lastUserPath.isEmpty { Self.cachedUserPath = lastUserPath }
                Self.cachedClaudePath = foundPath
                Self.cacheLock.unlock()
                return foundPath
            }
        }

        // Last resort: check the conventional install directories
        // directly. Covers users who keep claude on disk but whose
        // shells don't include the dir in PATH (asdf shims, custom
        // shell init files, …).
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]
        for candidate in candidates {
            if !pathLivesInsideAnotherCmuxBundle(candidate),
               FileManager.default.isExecutableFile(atPath: candidate) {
                Self.cacheLock.lock()
                if !lastUserPath.isEmpty { Self.cachedUserPath = lastUserPath }
                Self.cachedClaudePath = candidate
                Self.cacheLock.unlock()
                return candidate
            }
        }

        Self.cacheLock.lock()
        if !lastUserPath.isEmpty { Self.cachedUserPath = lastUserPath }
        Self.cacheLock.unlock()
        throw RunnerError.claudeNotFound
    }

    /// Spawn `shell` with `arguments` and parse the two-line stdout
    /// (PATH on the first line, the `command -v claude` result on the
    /// second). Returns `(foundPath, userPath)`; either may be empty.
    private func probeForClaude(shell: String, arguments: [String]) throws -> (String, String) {
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            return ("", "")
        }
        let probe = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        probe.executableURL = URL(fileURLWithPath: shell)
        probe.arguments = arguments
        probe.standardOutput = stdoutPipe
        probe.standardError = stderrPipe

        do {
            try probe.run()
        } catch {
            return ("", "")
        }
        probe.waitUntilExit()
        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let lines = stdout.split(separator: "\n").map(String.init)
        let userPath = (lines.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let foundPath = (lines.dropFirst().first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (foundPath, userPath)
    }

    /// True if `path` is `claude` shipped inside some other `cmux.app`
    /// bundle — i.e. it's the binary that the cmux installer drops into
    /// `Resources/bin/`. We skip those in the fork because the binary
    /// belongs to the sibling install, not to the user's "I installed
    /// claude" expectation.
    private func pathLivesInsideAnotherCmuxBundle(_ path: String) -> Bool {
        guard path.contains(".app/Contents/Resources/bin/claude") else { return false }
        let myBundlePath = Bundle.main.bundlePath
        return !path.hasPrefix(myBundlePath)
    }
}
